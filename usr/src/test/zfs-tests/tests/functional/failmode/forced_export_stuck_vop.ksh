#!/bin/ksh -p
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# http://www.illumos.org/license/CDDL.
#

#
# Copyright 2026 Oxide Computer Company
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/failmode/failmode.kshlib

#
# DESCRIPTION:
#	A vnode operation asleep outside a failed pool doesn't keep the
#	pool's export waiting past its deadline.  The operation holds its file
#	system's z_teardown_lock as reader, which the export's detach of the
#	file system takes as writer: the export returns EBUSY at the deadline,
#	and operations on the file system don't wait behind it.  Once the
#	operation is done, the export succeeds.
#
# STRATEGY:
#	1. Create a failmode=death pool with a file system mounted outside
#	   the pool's root file system (which the export detaches, failing
#	   lookups through it), and a cached file in it.  Create a second,
#	   healthy pool with a file in it, and import that pool again, so that
#	   the file isn't cached.
#	2. Map a page of the second pool's file, fail the first pool, make the
#	   second pool's I/O take 40 seconds longer than the export's deadline
#	   (20 seconds by default) ("zinject -D"), and read the first pool's
#	   file into the mapped page.  The read holds the file system's
#	   z_teardown_lock while it faults the page in (DTrace says when it
#	   does).
#	3. "zpool export" of the failed pool returns EBUSY at its deadline,
#	   while the read is still asleep.
#	4. Operations on the file system, from many threads (z_teardown_lock
#	   is one lock per thread hash), don't wait.
#	5. Once the read is done, operations still don't wait, and "zpool
#	   export" succeeds and unmounts the file system.  Import the pool,
#	   and check its data and its scrub.
#

verify_runnable "global"

typeset DIR=$TEST_BASE_DIR/stuck_vop
typeset MNT=$DIR/mnt
typeset VDEV2=$DIR/vdev2
typeset PY=$DIR/reader.py
typeset D=$DIR/stuck_vop.d
typeset DOUT=$DIR/stuck_vop.out
typeset ERR=$DIR/export.err
typeset rpid="" dpid="" epid=""

function cleanup
{
	[[ -n $dpid ]] && kill $dpid >/dev/null 2>&1
	[[ -n $rpid ]] && kill -9 $rpid >/dev/null 2>&1
	# The read, and an export waiting for it, end with the delayed I/O.
	failmode_reap $dpid $rpid $epid
	zinject -c all >/dev/null 2>&1
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	failmode_cleanup
	umount -f $MNT >/dev/null 2>&1
	rm -rf $DIR
}

#
# Operations on the file system, from many processes at once, all finish
# within 10 seconds.
#
function vops_proceed # when
{
	typeset -a lp
	typeset -i i t=10
	typeset p alive

	for ((i = 0; i < 34; i++)); do
		ls -l $MNT >/dev/null 2>&1 &
		lp[i]=$!
	done
	while :; do
		alive=""
		for p in ${lp[@]}; do
			kill -0 $p 2>/dev/null && alive="$alive $p"
		done
		[[ -z $alive ]] && break
		((t-- == 0)) && log_fail "operations on $MNT are blocked $1"
		sleep 1
	done
	wait ${lp[@]}
	log_note "operations on $MNT don't wait $1"
}

log_assert "A vnode operation asleep outside a failed pool doesn't keep" \
    "its export waiting past the deadline"
log_onexit cleanup

rm -rf $DIR
log_must mkdir -p $DIR

# The export's deadline, in seconds (spa_exit_deadline()), and the delay.
typeset -i txg_timeout=$(get_tunable zfs_txg_timeout)
((txg_timeout > 0)) || log_fail "can't read zfs_txg_timeout"
typeset -i deadline=$((4 * txg_timeout)) delay=$((4 * txg_timeout + 40))
log_note "deadline $deadline s, I/O delay $delay s"

failmode_create_pool death
log_must zfs set mountpoint=$MNT $TESTPOOL/$TESTFS
log_must zfs set atime=off $TESTPOOL/$TESTFS
log_must dd if=/dev/urandom of=$MNT/src bs=128k count=1
# Read it (not with cp, which maps it), so that its data is cached.
log_must dd if=$MNT/src of=$DIR/src.copy bs=128k
log_must zpool sync $TESTPOOL

log_must mkfile $MINVDEVSIZE $VDEV2
log_must zpool create -f -O atime=off $TESTPOOL1 $VDEV2
log_must dd if=/dev/urandom of=/$TESTPOOL1/buf bs=128k count=1
log_must zpool export $TESTPOOL1
log_must zpool import -d $DIR $TESTPOOL1

cat > $PY <<'EOF'
# reader.py <src> <buf> <dir>: map a page of <buf> and open <src>, create
# <dir>/ready, and once <dir>/go exists, read <src> into the mapped page.
import mmap, os, sys, time
src, buf, d = sys.argv[1:4]
pg = os.sysconf("SC_PAGESIZE")
fd = os.open(buf, os.O_RDWR)
m = mmap.mmap(fd, pg)
os.close(fd)
sfd = os.open(src, os.O_RDONLY)
open(os.path.join(d, "ready"), "w").close()
while not os.path.exists(os.path.join(d, "go")):
	time.sleep(0.1)
print("read %d bytes" % os.readv(sfd, [m]))
EOF
python $PY $MNT/src /$TESTPOOL1/buf $DIR > $DIR/reader.out 2>&1 &
rpid=$!
typeset -i t=30
until [[ -f $DIR/ready ]]; do
	kill -0 $rpid 2>/dev/null ||
	    log_fail "the reader failed: $(cat $DIR/reader.out)"
	((t-- == 0)) && log_fail "the reader didn't start"
	sleep 1
done

cat > $D <<'EOF'
#pragma D option quiet
#pragma D option switchrate=100hz
int faulting;

BEGIN
{
	printf("ready\n");
}

fbt::zfs_read:entry
/pid == $1/
{
	self->r = 1;
}

/* The read faults in the mapped page that it copies to. */
fbt::fop_getpage:entry
/self->r && !faulting/
{
	faulting = 1;
	printf("faulting\n");
}

fbt::zfs_read:return
/self->r/
{
	self->r = 0;
	printf("read returned %d\n", arg1);
}
EOF
dtrace -s $D $rpid > $DOUT 2>&1 &
dpid=$!
t=40
until grep -q "^ready" $DOUT 2>/dev/null; do
	kill -0 $dpid 2>/dev/null || log_fail "dtrace failed: $(cat $DOUT)"
	((t-- == 0)) && log_fail "dtrace didn't start"
	sleep 0.5
done

failmode_break_vdev
(dd if=/dev/urandom of=$MNT/dirty bs=128k count=4;
    zpool sync $TESTPOOL) >/dev/null 2>&1 &
failmode_wait_failed $TESTPOOL

# Every I/O to the second pool's disk now takes $delay seconds.
log_must eval "zinject -d $VDEV2 -D $((delay * 1000)):16 $TESTPOOL1 \
    >/dev/null"
log_must touch $DIR/go
t=30
until grep -q "^faulting" $DOUT; do
	((t-- == 0)) && log_fail "the read didn't fault: $(cat $DOUT)"
	sleep 1
done
sleep 2
grep -q "^read returned" $DOUT &&
    log_fail "the page fault wasn't delayed: $(cat $DOUT)"
# The injection handlers hold the pools.  The delayed read stays delayed.
log_must zinject -c all

zpool export $TESTPOOL > $ERR 2>&1 &
epid=$!
typeset -i start=$SECONDS
t=$((deadline + 15))
while kill -0 $epid 2>/dev/null; do
	((t-- == 0)) && log_fail "zpool export waited for the read"
	sleep 1
done
wait $epid
typeset -i rc=$? took=$((SECONDS - start))
epid=""
log_note "zpool export returned $rc after $took seconds: $(cat $ERR)"
grep -q "^read returned" $DOUT &&
    log_fail "the read ended before the export did: $(cat $DOUT)"
log_mustnot test $rc -eq 0
log_must grep -q busy $ERR
# It returned at the deadline, not for some other reason.
log_must test $took -ge $((deadline - 5))
log_must poolexists $TESTPOOL
log_must pool_has_failed $TESTPOOL

vops_proceed "after the export gave up"

t=$((delay + 30))
until grep -q "^read returned" $DOUT; do
	((t-- == 0)) && log_fail "the read never returned: $(cat $DOUT)"
	sleep 1
done
wait $rpid
rpid=""
log_note "$(cat $DOUT) $(cat $DIR/reader.out)"
kill $dpid >/dev/null 2>&1
wait $dpid
dpid=""

vops_proceed "after the read"

run_within 30 "zpool export of the failed pool" zpool export $TESTPOOL
log_must test $within_rc -eq 0
log_mustnot poolexists $TESTPOOL
log_mustnot eval "mount -p | grep -q ' $MNT zfs '"

log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
log_must cmp $MNT/src $DIR/src.copy
log_must zpool scrub -w $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

log_pass "A vnode operation asleep outside a failed pool doesn't keep" \
    "its export waiting past the deadline"
