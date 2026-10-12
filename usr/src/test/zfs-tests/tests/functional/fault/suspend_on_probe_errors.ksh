#!/bin/ksh -p
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or https://opensource.org/licenses/CDDL-1.0.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#

#
# Copyright (c) 2024, Klara Inc.
#

. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION: Verify that 4 disks failing in a raidz3 will suspend the pool
#
# STRATEGY:
# 1. Create a raidz3 pool of file vdevs
# 2. Add some data to it for a resilver workload
# 3. Replace one of the child vdevs to start a replacing vdev
# 4. During the resilver, use zinject to fail I/O and vdev probes on 4 disks,
#    including the one being replaced
# 5. Verify that the pool is suspended (it used to remain online)
#

FILE_VDEV_CNT=8
FILE_VDEV_SIZ=256M

function pool_is_suspended # pool
{
	zpool status $1 | grep -q -E "ZFS-8000-(HC|JQ)"
}

function cleanup
{
	zinject -c all
	# zpool status can miss a suspension; clearing is harmless.
	poolexists $TESTPOOL && zpool clear $TESTPOOL
	log_must set_tunable32 zfs_scan_suspend_progress 0
	destroy_pool $TESTPOOL
	for i in {0..$((FILE_VDEV_CNT - 1))}; do
		log_must rm -f "$TEST_BASE_DIR/dev-$i"
	done
}

log_onexit cleanup

log_assert "VDEV probe errors for more disks than parity should suspend a pool"

# Create 8 file vdevs
typeset -a filedevs
for i in {0..$((FILE_VDEV_CNT - 1))}; do
	device=$TEST_BASE_DIR/dev-$i
	log_must truncate -s $FILE_VDEV_SIZ $device
	# Use all but the last one for pool create
	if ((i < 7)); then
		filedevs[${#filedevs[*]}+1]=$device
	fi
done

# Create a raidz-3 pool that we can fail 4 disks in
log_must zpool create -f $TESTPOOL raidz3 ${filedevs[@]}
sync_pool $TESTPOOL

# Add some data to the pool
log_must zfs create $TESTPOOL/fs
MNTPOINT="$(get_prop mountpoint $TESTPOOL/fs)"
log_must dd if=/dev/urandom of=$MNTPOINT/data bs=1M count=200
sync_pool $TESTPOOL

# Start a replacing vdev, but suspend the resilver
log_must set_tunable32 zfs_scan_suspend_progress 1
log_must zpool replace -f $TESTPOOL $TEST_BASE_DIR/dev-6 $TEST_BASE_DIR/dev-7

# Fail 4 disks all at once: their I/O fails, and so do the probes that follow
for i in {3..6}; do
	log_must zinject -d $TEST_BASE_DIR/dev-$i -e io -T all $TESTPOOL
	log_must zinject -d $TEST_BASE_DIR/dev-$i -L pad2 $TESTPOOL
done

log_must set_tunable32 zfs_scan_suspend_progress 0

# Add some writes to drive the vdev probe errors
log_must dd if=/dev/urandom of=$MNTPOINT/writes bs=1M count=1

# Wait until sync starts, and the pool suspends
log_note "waiting for pool to suspend"
typeset -i tries=30
until pool_is_suspended $TESTPOOL; do
	if ((tries-- == 0)); then
		zpool status -v $TESTPOOL
		log_fail "UNEXPECTED -- pool did not suspend"
	fi
	sleep 1
done
zpool status $TESTPOOL

# Put the missing disks back into service
log_must zinject -c all

# Clear the vdev error states, which will reopen the vdevs and resume the pool
log_must zpool clear $TESTPOOL

# Wait until the pool resumes
log_note "waiting for pool to resume"
tries=30
while pool_is_suspended $TESTPOOL; do
	if ((tries-- == 0)); then
		log_fail "pool did not resume"
	fi
	sleep 1
done
#
# The disks that missed writes while they were failing get a deferred
# resilver, which the async thread starts only after the first one finishes,
# so it can begin after "zpool wait" returns.  Wait for that one too.
#
typeset -i tries=30
while true; do
	log_must zpool wait -t resilver $TESTPOOL
	sync_pool $TESTPOOL
	sleep 1
	is_pool_resilvering $TESTPOOL || break
	((tries-- == 0)) && log_fail "resilver did not finish"
done

# Make sure a pool scrub comes back clean
log_must zpool scrub -w $TESTPOOL
log_must zpool status -v $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

log_pass "VDEV probe errors for more disks than parity should suspend a pool"
