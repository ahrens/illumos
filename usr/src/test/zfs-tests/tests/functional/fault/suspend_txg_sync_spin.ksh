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

#
# DESCRIPTION:
#	The txg sync thread must not spin while its pool is suspended.
#
# STRATEGY:
#	1. Create a raidz3 pool of file vdevs with a resilver in progress.
#	2. Fail I/O and vdev probes on 4 disks, so that the pool is suspended
#	   by the async thread rather than from within spa_sync().
#	3. Profile the kernel and verify that the txg sync thread is not
#	   running most of the time.
#

FILE_VDEV_CNT=8
FILE_VDEV_SIZ=256M

function pool_is_suspended # pool
{
	zpool status $1 | grep -q -E "ZFS-8000-(HC|JQ)"
}

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
	poolexists $TESTPOOL && zpool clear $TESTPOOL
	log_must set_tunable32 zfs_scan_suspend_progress 0
	destroy_pool $TESTPOOL
	for i in {0..$((FILE_VDEV_CNT - 1))}; do
		log_must rm -f "$TEST_BASE_DIR/dev-$i"
	done
}

log_onexit cleanup

log_assert "The txg sync thread does not spin while the pool is suspended"

typeset -a filedevs
for i in {0..$((FILE_VDEV_CNT - 1))}; do
	device=$TEST_BASE_DIR/dev-$i
	log_must truncate -s $FILE_VDEV_SIZ $device
	if ((i < 7)); then
		filedevs[${#filedevs[*]}+1]=$device
	fi
done

log_must zpool create -f $TESTPOOL raidz3 ${filedevs[@]}
log_must zfs create $TESTPOOL/fs
MNTPOINT="$(get_prop mountpoint $TESTPOOL/fs)"
log_must dd if=/dev/urandom of=$MNTPOINT/data bs=1M count=100
sync_pool $TESTPOOL

# Keep a resilver in progress, so the sync thread has a scan to look at.
log_must set_tunable32 zfs_scan_suspend_progress 1
log_must zpool replace -f $TESTPOOL $TEST_BASE_DIR/dev-6 $TEST_BASE_DIR/dev-7
log_must is_pool_resilvering $TESTPOOL

for i in {3..6}; do
	log_must zinject -d $TEST_BASE_DIR/dev-$i -e io -T all $TESTPOOL
	log_must zinject -d $TEST_BASE_DIR/dev-$i -L pad2 $TESTPOOL
done
log_must dd if=/dev/urandom of=$MNTPOINT/writes bs=1M count=1

log_note "waiting for pool to suspend"
typeset -i tries=30
until pool_is_suspended $TESTPOOL; do
	if ((tries-- == 0)); then
		zpool status -v $TESTPOOL
		log_fail "pool did not suspend"
	fi
	sleep 1
done

# Let the txg timeout pass too, then look for the sync thread on CPU.
sleep 10
typeset -i samples=$(txg_sync_samples)
log_note "txg sync thread seen on CPU in $samples samples (5s at 997Hz)"
# A thread that spins is seen in nearly every one of its CPU's ~5000 samples.
((samples < 1000)) || log_fail "txg sync thread spins while suspended"

log_must zinject -c all
log_must zpool clear $TESTPOOL
log_must set_tunable32 zfs_scan_suspend_progress 0

log_pass "The txg sync thread does not spin while the pool is suspended"
