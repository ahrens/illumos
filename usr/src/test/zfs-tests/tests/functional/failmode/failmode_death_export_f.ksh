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
#	"zpool export -f" removes a failmode=death pool whose device has
#	stopped working even if the pool hasn't failed yet: the export's own
#	sync fails it, and the export goes on.
#

log_assert "zpool export -f of an idle failmode=death pool on a failed" \
    "device finishes"
log_onexit failmode_cleanup

failmode_create_pool death
sync_pool $TESTPOOL
failmode_break_vdev
log_mustnot pool_has_failed $TESTPOOL

zpool export -f $TESTPOOL &
typeset -i export_pid=$!
failmode_wait_failed $TESTPOOL
log_must zinject -c all
typeset -i tries=60
while kill -0 $export_pid 2>/dev/null; do
	if ((tries-- == 0)); then
		log_fail "zpool export -f did not finish"
	fi
	sleep 1
done
log_must wait $export_pid
log_mustnot poolexists $TESTPOOL

log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
log_must zpool scrub $TESTPOOL
log_must wait_scrubbed $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

log_pass "zpool export -f of an idle failmode=death pool on a failed" \
    "device finishes"
