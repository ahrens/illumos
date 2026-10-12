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
#	A failmode=death raidz3 that loses four disks during a resilver,
#	with their I/O and vdev probes failing, fails rather than staying
#	online or suspending.  The txg sync thread doesn't spin on the
#	failed pool, zpool export -f removes it, and once the disks are back
#	it imports with what it had synced.  (fault/suspend_on_probe_errors
#	and fault/suspend_txg_sync_spin are the same scenario for a pool
#	that suspends.)  The fourth disk is the one being replaced, so the
#	pool fails only once a failed probe of a disk the raidz needs stops
#	it (OpenZFS 939e0237c5); until that is ported, this test is left
#	out of common.run.
#
# STRATEGY:
#	1. Create a failmode=death raidz3 pool of file vdevs, with data
#	2. Start replacing one of them, with the resilver paused
#	3. Fail I/O and probes on four disks, including the one being
#	   replaced, and write to the pool
#	4. The pool must fail, not suspend
#	5. Sample the txg sync thread with DTrace: it must not be on CPU
#	   most of the time
#	6. zpool export -f must remove the pool within 60 seconds
#	7. Clear the faults, import, finish the resilver and scrub: no
#	   errors, and the data written before is intact
#

verify_runnable "global"

FILE_VDEV_CNT=8
FILE_VDEV_SIZ=256M

#
# Print the number of times the txg sync thread was found on a CPU while
# sampling every CPU at 997Hz for 5 seconds.
#
function txg_sync_samples
{
	typeset n=$(dtrace -q -n 'profile-997
	    /arg0 && (uintptr_t)curthread->t_startpc ==
	    (uintptr_t)&zfs`txg_sync_thread/ { @ = count(); }
	    tick-5s { printa("%@d\n", @); exit(0); }')
	echo ${n:-0}
}

function cleanup
{
	zinject -c all
	poolexists $TESTPOOL && pool_has_failed $TESTPOOL &&
	    zpool export -f $TESTPOOL
	set_tunable32 zfs_scan_suspend_progress 0
	poolexists $TESTPOOL && destroy_pool $TESTPOOL
	for i in {0..$((FILE_VDEV_CNT - 1))}; do
		rm -f "$TEST_BASE_DIR/dev-$i"
	done
}

log_onexit cleanup

log_assert "A death raidz3 that loses four disks to probe errors fails"

typeset -a filedevs
for i in {0..$((FILE_VDEV_CNT - 1))}; do
	device=$TEST_BASE_DIR/dev-$i
	log_must truncate -s $FILE_VDEV_SIZ $device
	if ((i < 7)); then
		filedevs[${#filedevs[*]}+1]=$device
	fi
done

log_must zpool create -f -o failmode=death $TESTPOOL raidz3 ${filedevs[@]}
log_must zfs create $TESTPOOL/fs
MNTPOINT="$(get_prop mountpoint $TESTPOOL/fs)"
log_must dd if=/dev/urandom of=$MNTPOINT/data bs=1M count=200
sync_pool $TESTPOOL
typeset cksum=$(sha256digest $MNTPOINT/data)

log_must set_tunable32 zfs_scan_suspend_progress 1
log_must zpool replace -f $TESTPOOL $TEST_BASE_DIR/dev-6 $TEST_BASE_DIR/dev-7
log_must is_pool_resilvering $TESTPOOL

for i in {3..6}; do
	log_must zinject -d $TEST_BASE_DIR/dev-$i -e io -T all $TESTPOOL
	log_must zinject -d $TEST_BASE_DIR/dev-$i -L pad2 $TESTPOOL
done
log_must set_tunable32 zfs_scan_suspend_progress 0
log_must dd if=/dev/urandom of=$MNTPOINT/writes bs=1M count=1

failmode_wait_failed $TESTPOOL
log_mustnot pool_is_suspended $TESTPOOL
zpool status $TESTPOOL

# Let the txg timeout pass too, then look for the sync thread on CPU.
sleep 10
typeset -i samples=$(txg_sync_samples)
log_note "txg sync thread seen on CPU in $samples samples (5s at 997Hz)"
# A thread that spins is seen in nearly every one of its CPU's ~5000 samples.
((samples < 1000)) || log_fail "txg sync thread spins on the failed pool"

# zinject handlers hold the pool; clearing them can't revive a failed pool.
log_must zinject -c all
log_must pool_has_failed $TESTPOOL
run_within 60 "zpool export -f" zpool export -f $TESTPOOL
log_must test $within_rc -eq 0
log_mustnot poolexists $TESTPOOL

log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
#
# The disks that missed writes get a deferred resilver, which can start
# after the first one finishes; wait for that too.
#
typeset -i tries=30
while true; do
	log_must zpool wait -t resilver $TESTPOOL
	sync_pool $TESTPOOL
	sleep 1
	is_pool_resilvering $TESTPOOL || break
	((tries-- == 0)) && log_fail "resilver did not finish"
done
log_must zpool scrub -w $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"
log_must test "$cksum" = "$(sha256digest $MNTPOINT/data)"

log_pass "A death raidz3 that loses four disks to probe errors fails"
