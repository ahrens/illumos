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
#	A suspended pool's health is reported as SUSPENDED by "zpool list",
#	"zpool get" and the state line of "zpool status", and goes back to
#	ONLINE once the pool resumes.
#

function check_health # expected
{
	log_must test "$(zpool list -H -o health $TESTPOOL)" = "$1"
	log_must test "$(zpool get -H -o value health $TESTPOOL)" = "$1"
	log_must eval "zpool status $TESTPOOL | grep -q '^ *state: $1\$'"
}

log_assert "A suspended pool's health is SUSPENDED"
log_onexit failmode_cleanup

for mode in wait continue; do
	failmode_create_pool $mode
	check_health ONLINE
	failmode_suspend_pool
	check_health SUSPENDED
	failmode_resume_pool
	check_health ONLINE
	failmode_cleanup
done

log_pass "A suspended pool's health is SUSPENDED"
