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
#	If "zpool export -F" of a suspended pool fails because something still
#	holds the pool, it leaves the pool failed, and once the holder is gone,
#	running it again exports the pool.  The holder here is a fault
#	injection handler, which keeps a pool from being exported.  (A busy
#	file system can't be the holder: a forced unmount succeeds even with
#	another file system mounted on top of it.)
#

function cleanup
{
	zinject -c all >/dev/null 2>&1
	pool_is_suspended $TESTPOOL && zpool clear $TESTPOOL
	failmode_cleanup
}

log_assert "zpool export -F that fails on a held pool can be run again"
log_onexit cleanup

failmode_create_pool wait
failmode_suspend_pool

# The injection handlers are still there, and hold the pool.
run_within 60 "zpool export -fF of a held pool" zpool export -fF $TESTPOOL
log_mustnot test $within_rc -eq 0
log_must poolexists $TESTPOOL
log_must pool_has_failed $TESTPOOL

# It has failed: zpool clear can't resume it, and zpool status says so.
log_mustnot zpool clear $TESTPOOL
log_must pool_has_failed $TESTPOOL
zpool status $TESTPOOL | grep -q "^ *state: FAILED" ||
    log_fail "zpool status doesn't show the pool as FAILED"

log_must zinject -c all
run_within 60 "zpool export -fF once nothing holds the pool" \
    zpool export -fF $TESTPOOL
log_must test $within_rc -eq 0
log_mustnot poolexists $TESTPOOL

log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
log_must zpool scrub $TESTPOOL
log_must wait_scrubbed $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

log_pass "zpool export -F that fails on a held pool can be run again"
