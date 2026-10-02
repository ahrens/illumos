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
#	"zpool status" must report a pool that suspends in the middle of a
#	resilver as suspended, not just as resilvering.
#
# STRATEGY:
#	1. Create a pool, write some data, and attach a mirror with the
#	   resilver held in progress.
#	2. Make writes and vdev probes fail on both sides of the mirror, and
#	   dirty the pool so that it suspends.
#	3. Verify that "zpool status" says so.
#

typeset ATTACH_VDEV=$TEST_BASE_DIR/failmode_vdev_attach

function cleanup
{
	log_must set_tunable32 zfs_scan_suspend_progress 0
	failmode_cleanup
	rm -f $ATTACH_VDEV
}

log_assert "A pool that suspends while resilvering is reported as suspended"
log_onexit cleanup

failmode_create_pool wait
log_must dd if=/dev/urandom of=/$TESTPOOL/$TESTFS/data bs=128k count=64
sync_pool $TESTPOOL

log_must set_tunable32 zfs_scan_suspend_progress 1
log_must mkfile $MINVDEVSIZE $ATTACH_VDEV
log_must zpool attach $TESTPOOL $FAILMODE_VDEV $ATTACH_VDEV
log_must is_pool_resilvering $TESTPOOL

for vdev in $FAILMODE_VDEV $ATTACH_VDEV; do
	log_must zinject -d $vdev -e io -T write $TESTPOOL
	log_must zinject -d $vdev -L pad2 $TESTPOOL
done
log_must dd if=/dev/urandom of=/$TESTPOOL/$TESTFS/dirty bs=128k count=8

log_note "waiting for pool to suspend"
typeset -i tries=30
until pool_is_suspended $TESTPOOL; do
	if ((tries-- == 0)); then
		zpool status -v $TESTPOOL
		log_fail "zpool status does not report the pool as suspended"
	fi
	sleep 1
done

failmode_resume_pool

log_pass "A pool that suspends while resilvering is reported as suspended"
