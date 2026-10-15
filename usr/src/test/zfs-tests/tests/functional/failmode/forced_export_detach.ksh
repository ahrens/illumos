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
#	A failed pool's mounted file systems don't keep it from being
#	exported, however busy they are: the kernel detaches them from the
#	pool as it exports it, rather than relying on their having been
#	unmounted.  They stay mounted, and every operation on them fails
#	with EIO, until "zpool export" unmounts them once the pool is gone,
#	nested ones first.  A failed pool's file systems can't be mounted.
#
# STRATEGY:
#	1. Create a failmode=death pool with a file system that has a tmpfs
#	   mounted in it, a busy file system (an open file, a process in it,
#	   a mounted snapshot in use, and a nested file system), and one that
#	   isn't mounted.
#	2. Fail the pool, and check that the unmounted file system can't be
#	   mounted.
#	3. Export the pool, stopping "zpool export" (with DTrace) once the
#	   pool is gone, before it unmounts the file systems.  Check that
#	   they are all still mounted, and fail with EIO.
#	4. Let "zpool export" finish, and check that it unmounted them all.
#	   The tmpfs is left mounted, though it can't be reached.
#	5. Import the pool, and check its data and its scrub.
#

typeset FS=/$TESTPOOL/$TESTFS
typeset BUSY=/$TESTPOOL/busy
typeset ERR=$TEST_BASE_DIR/detach_export.err
typeset D=$TEST_BASE_DIR/detach.d
typeset DOUT=$TEST_BASE_DIR/detach.d.out
typeset -a pids
typeset dpid="" epid=""

# The mountpoints of the pool's file systems that are mounted, deepest first.
function pool_mounts
{
	mount -p | nawk -v p=$TESTPOOL '
	    $4 == "zfs" && ($1 == p || index($1, p "/") == 1 ||
	    index($1, p "@") == 1) { print $3 }' | sort -r
}

function cleanup
{
	typeset pid m

	[[ -n $dpid ]] && kill $dpid >/dev/null 2>&1
	[[ -n $epid ]] && /usr/bin/prun $epid >/dev/null 2>&1
	for pid in ${pids[@]}; do
		kill -9 $pid >/dev/null 2>&1
	done
	wait
	umount $FS/tmp >/dev/null 2>&1
	for m in $(pool_mounts); do
		umount -f $m >/dev/null 2>&1
	done
	failmode_cleanup
	rm -f $ERR $D $DOUT
}

log_assert "A failed pool's busy file systems don't keep it from being" \
    "exported"
log_onexit cleanup

failmode_create_pool death
log_must mkdir $FS/tmp
log_must mount -F tmpfs swap $FS/tmp
log_must touch $FS/tmp/file
log_must dd if=/dev/urandom of=$FS/data bs=128k count=8

log_must zfs create $TESTPOOL/busy
log_must zfs create $TESTPOOL/busy/child
log_must zfs create -o canmount=noauto $TESTPOOL/unmounted
log_must touch $BUSY/held $BUSY/child/file
log_must zfs snapshot $TESTPOOL/busy@snap
sleep 3600 < $BUSY/held &
pids[0]=$!
(cd $BUSY && sleep 3600) &
pids[1]=$!
(cd $BUSY/.zfs/snapshot/snap && sleep 3600) &
pids[2]=$!
log_must zpool sync $TESTPOOL
sleep 1
log_note "mounted before the failure: $(pool_mounts | tr '\n' ' ')"
# The snapshot is mounted, though not in mnttab, if the cd worked.
log_must kill -0 ${pids[2]}

failmode_break_vdev
(dd if=/dev/urandom of=$FS/dirty bs=128k count=4;
    zpool sync $TESTPOOL) >/dev/null 2>&1 &
failmode_wait_failed $TESTPOOL
log_mustnot zfs mount $TESTPOOL/unmounted

# Stop "zpool export" as it returns from the export, before it unmounts.
cat > $D <<EOF
#pragma D option quiet
#pragma D option destructive
BEGIN
{
	printf("ready\\n");
}
fbt::zfs_ioc_pool_export:return
/execname == "zpool"/
{
	stop();
	printf("stopped %d, export returned %d\\n", pid, arg1);
	exit(0);
}
EOF
dtrace -s $D > $DOUT 2>&1 &
dpid=$!
typeset -i t=40
until grep -q "^ready" $DOUT 2>/dev/null; do
	kill -0 $dpid 2>/dev/null || log_fail "dtrace failed: $(cat $DOUT)"
	((t-- == 0)) && log_fail "dtrace didn't start"
	sleep 0.5
done

log_must zinject -c all
zpool export $TESTPOOL 2>$ERR &
epid=$!
t=60
while kill -0 $dpid 2>/dev/null; do
	((t-- == 0)) && log_fail "zpool export didn't finish the export"
	sleep 1
done
dpid=""
log_note "$(cat $DOUT)"
log_mustnot poolexists $TESTPOOL

# Every file system is still mounted, detached from the pool.
typeset mounted=$(pool_mounts | tr '\n' ' ')
log_note "mounted after the export: $mounted"
[[ $mounted == "$FS $BUSY/child $BUSY /$TESTPOOL " ]] ||
    log_fail "the pool's file systems aren't all mounted"
log_mustnot ls $FS
log_mustnot stat $FS/data
log_mustnot ls $BUSY/child
log_mustnot cat $BUSY/held
log_must kill -0 ${pids[0]} ${pids[1]} ${pids[2]}

# Let "zpool export" unmount them.
log_must /usr/bin/prun $epid
t=60
while kill -0 $epid 2>/dev/null; do
	((t-- == 0)) && log_fail "zpool export didn't finish"
	sleep 1
done
wait $epid
typeset rc=$?
epid=""
log_note "zpool export returned $rc: $(cat $ERR)"
log_must test $rc -eq 0
log_mustnot test -s $ERR
[[ -z $(pool_mounts) ]] || log_fail "left mounted: $(pool_mounts)"
log_must kill -0 ${pids[0]} ${pids[1]} ${pids[2]}

# The tmpfs is still mounted, though nothing leads to it.
log_must eval "mount -p | grep -q ' $FS/tmp tmpfs '"
log_must umount $FS/tmp

kill -9 ${pids[@]}
wait
pids=()
log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
log_must test -f $FS/data
log_must test -f $BUSY/child/file
log_must snapexists $TESTPOOL/busy@snap
log_must zpool scrub -w $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

log_pass "A failed pool's busy file systems don't keep it from being" \
    "exported"
