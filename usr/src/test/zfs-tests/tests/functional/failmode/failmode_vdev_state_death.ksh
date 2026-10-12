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
# Copyright (c) 2026 by the OpenZFS project.  All rights reserved.
# Copyright 2026 Oxide Computer Company
#
. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/failmode/failmode.kshlib

#
# DESCRIPTION:
#	A vdev state change returns when a failmode=death pool fails
#	while it waits for its txg to sync.  (failmode_vdev_state is the
#	same test for a pool that suspends.)
#
# STRATEGY:
#	1. Create a failmode=death mirror and stop background txg syncs
#	2. Fail every write and every probe on both sides of the
#	   mirror
#	3. Run zpool online, whose txg sync fails the pool
#	4. zpool online must return within the timeout, the pool must
#	   have failed, and zpool export -f must remove it
#

verify_runnable "global"

log_assert "A vdev state change returns when a death pool fails"

typeset -i STATE_TIMEOUT=60
typeset -i zpid=0
typeset txg_timeout=$(get_tunable zfs_txg_timeout)

#
# Wait up to STATE_TIMEOUT seconds for zpool online to exit.
#
function wait_online
{
	typeset -i waited=0

	while kill -0 $zpid 2>/dev/null; do
		((waited++ >= STATE_TIMEOUT)) && return 1
		sleep 1
	done
	return 0
}

function cleanup
{
	zinject -c all
	poolexists $TESTPOOL && pool_has_failed $TESTPOOL &&
	    zpool export -f $TESTPOOL
	poolexists $TESTPOOL && zpool clear $TESTPOOL
	if ((zpid > 0)); then
		if wait_online; then
			wait $zpid
		else
			log_note "zpool online is still running"
		fi
	fi
	set_tunable32 zfs_txg_timeout $txg_timeout
	poolexists $TESTPOOL && destroy_pool $TESTPOOL
	zpool labelclear -f $DISK1
	zpool labelclear -f $DISK2
}

read -r DISK1 DISK2 _ <<<"$DISKS"
if [[ -z "$DISK2" ]]; then
	log_unsupported "this test needs two disks"
fi

log_onexit cleanup
log_must set_tunable32 zfs_txg_timeout 600

log_must zpool create -f -o failmode=death $TESTPOOL mirror $DISK1 $DISK2
log_must zpool sync $TESTPOOL

log_must zinject -d $DISK1 -e io -T write $TESTPOOL
log_must zinject -d $DISK2 -e io -T write $TESTPOOL
log_must zinject -d $DISK1 -L pad2 $TESTPOOL
log_must zinject -d $DISK2 -L pad2 $TESTPOOL
log_mustnot pool_has_failed $TESTPOOL

zpool online $TESTPOOL $DISK1 &
zpid=$!

if ! wait_online; then
	log_fail "zpool online hung for ${STATE_TIMEOUT}s"
fi
wait $zpid
typeset -i rc=$?
zpid=0

#
# The vdev state change itself is already in memory, so zpool online may
# return either way; what matters is that it returned.
#
log_note "zpool online returned $rc"
log_must pool_has_failed $TESTPOOL
log_mustnot pool_is_suspended $TESTPOOL
# zinject handlers hold the pool; clearing them can't revive a failed pool.
log_must zinject -c all
log_must zpool export -f $TESTPOOL
log_mustnot poolexists $TESTPOOL

log_pass "A vdev state change returns when a death pool fails"
