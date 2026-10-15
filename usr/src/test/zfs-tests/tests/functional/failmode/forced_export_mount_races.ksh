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
#	"zpool export -F" of a suspended pool finishes when it races with a
#	mount or an unmount of one of the pool's file systems that the
#	failing pool wakes up:
#	- A mount waiting in its log replay fails, and leaves nothing
#	  mounted, rather than finishing after the export has looked for
#	  file systems to unmount, and keeping the pool busy.
#	- An online incremental receive waiting to finish, whose resume of
#	  the file system then fails and unmounts it, doesn't keep the pool
#	  or its other file systems busy.
#
# STRATEGY:
#	1. Block the operation on the suspended failmode=wait pool, and hold
#	   it for a while (with DTrace) once the export wakes it, so that the
#	   export runs while it finishes.
#	2. Run "zpool export -F", check that it finishes within 60 seconds,
#	   that the operation fails, and that none of the pool's file systems
#	   are left mounted.
#	3. Import the pool and scrub it.
#

typeset DIR=$TEST_BASE_DIR/mount_races
typeset SRC=$TESTPOOL1/src
typeset V2=$DIR/v2
typeset dpid="" opid=""

# The pool's file systems that are mounted.
function pool_mounts
{
	mount -p | nawk -v p=$TESTPOOL '
	    $4 == "zfs" && ($1 == p || index($1, p "/") == 1) { print $3 }'
}

function cleanup
{
	[[ -n $dpid ]] && kill $dpid >/dev/null 2>&1
	[[ -n $opid ]] && kill -9 $opid >/dev/null 2>&1
	wait
	typeset m
	for m in $(pool_mounts | sort -r); do
		umount -f $m >/dev/null 2>&1
	done
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	failmode_cleanup
	rm -rf $DIR
}

#
# Hold the zfs command for 300ms at <probe> once the pool fails, with any
# other D clauses in <extra>.
#
function start_d # probe extra
{
	cat > $DIR/race.d <<EOF
#pragma D option quiet
#pragma D option destructive
#pragma D option switchrate=100hz
int done;
BEGIN
{
	printf("ready\\n");
}
fbt::$1 /execname == "zfs"/
{
	printf("%d woke: %s\\n", timestamp / 1000000, probefunc);
	chill(300000000);
}
$2
EOF
	dtrace -s $DIR/race.d > $DIR/d.out 2>&1 &
	dpid=$!
	typeset -i t=40
	until grep -q "^ready" $DIR/d.out 2>/dev/null; do
		kill -0 $dpid 2>/dev/null || log_fail "dtrace failed: $(cat $DIR/d.out)"
		((t-- == 0)) && log_fail "dtrace didn't start"
		sleep 0.5
	done
}

# Wait for the pool to suspend, export it, and check what's left.
function export_racing # what
{
	failmode_wait_stopped $TESTPOOL wait
	sleep 2
	# A fault injection handler would keep the pool busy.
	log_must zinject -c all
	run_within 60 "zpool export -F during the $1" \
	    zpool export -F $TESTPOOL
	log_must test $within_rc -eq 0
	log_mustnot poolexists $TESTPOOL

	typeset -i t=30
	while kill -0 $opid 2>/dev/null; do
		((t-- == 0)) && log_fail "the $1 is still running"
		sleep 1
	done
	wait $opid
	opid=""
	log_note "the $1: $(cat $DIR/op.out)"
	kill $dpid >/dev/null 2>&1
	wait $dpid
	dpid=""
	log_note "dtrace: $(cat $DIR/d.out)"
	log_must grep -q "rc [1-9]" $DIR/op.out
	[[ -z $(pool_mounts) ]] || log_fail "left mounted after the $1:" \
	    "$(pool_mounts)"

	log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
	log_must zpool scrub -w $TESTPOOL
	log_must check_pool_status $TESTPOOL "errors" "No known data errors"
}

log_assert "zpool export -F of a suspended pool finishes when it races" \
    "with a mount or an unmount"
log_onexit cleanup
log_must mkdir -p $DIR

#
# A mount in its log replay.  Freezing the pool leaves the synchronous
# writes in the log for the mount to replay.
#
failmode_create_pool wait
typeset dsync="os.O_WRONLY | os.O_CREAT | os.O_DSYNC"
log_must python -c "import os; \
    fd = os.open('/$TESTPOOL/$TESTFS/first', $dsync); os.write(fd, b'x')"
log_must zpool sync $TESTPOOL
log_must zpool freeze $TESTPOOL
log_must python -c "import os; fd = os.open('/$TESTPOOL/$TESTFS/f', $dsync); \
    [os.pwrite(fd, os.urandom(131072), i * 131072) for i in range(64)]"
log_must zpool export $TESTPOOL
log_must zpool import -N -d $TEST_BASE_DIR $TESTPOOL
# Its mountpoint is in the pool's root.
log_must zfs mount $TESTPOOL
start_d "zil_replay:return"
failmode_break_vdev
(zfs mount $TESTPOOL/$TESTFS; echo "rc $?") > $DIR/op.out 2>&1 &
opid=$!
export_racing "mount"
log_must ismounted $TESTPOOL/$TESTFS
log_must zpool destroy $TESTPOOL

#
# An online incremental receive.  Its writes go to a pool that is healthy
# until it finishes (dmu_recv_end()).
#
failmode_create_pool wait
log_must mkfile $MINVDEVSIZE $V2
log_must zpool create -f $TESTPOOL1 $V2
log_must zfs create -o compression=off $SRC
log_must dd if=/dev/urandom of=/$SRC/a bs=1024k count=16
log_must zfs snapshot $SRC@s1
log_must dd if=/dev/urandom of=/$SRC/b bs=1024k count=16
log_must zfs snapshot $SRC@s2
log_must eval "zfs send $SRC@s1 | zfs recv $TESTPOOL/dst"
log_must ismounted $TESTPOOL/dst
start_d "zfs_resume_fs:entry" "fbt::dmu_recv_end:entry
/execname == \"zfs\" && !done/
{
	done = 1;
	system(\"zinject -d $FAILMODE_VDEV -e io -T write $TESTPOOL\");
	chill(300000000);
}"
(zfs send -i @s1 $SRC@s2 | zfs recv -F $TESTPOOL/dst; echo "rc $?") \
    > $DIR/op.out 2>&1 &
opid=$!
export_racing "receive"

log_pass "zpool export -F of a suspended pool finishes when it races" \
    "with a mount or an unmount"
