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
#	"zpool export -F" of an idle pool whose device has stopped working
#	finishes: it fails the pool, so the export doesn't try to sync, and
#	nothing waits for the device.
#

log_assert "zpool export -F of an idle pool on a failed device finishes"
log_onexit failmode_cleanup

failmode_create_pool wait
sync_pool $TESTPOOL
log_must zinject -d $FAILMODE_VDEV -e io -T all $TESTPOOL
log_must zinject -d $FAILMODE_VDEV -L pad2 $TESTPOOL

#
# The injection handlers hold the pool, which keeps it from being exported
# until they are cleared, so clear them once the pool has failed.
#
zpool export -F $TESTPOOL &
typeset -i export_pid=$!
failmode_wait_failed $TESTPOOL
log_must zinject -c all
typeset -i tries=60
while kill -0 $export_pid 2>/dev/null; do
	if ((tries-- == 0)); then
		log_fail "zpool export -F did not finish"
	fi
	sleep 1
done
log_must wait $export_pid
log_mustnot poolexists $TESTPOOL

log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
log_must zpool scrub $TESTPOOL
log_must wait_scrubbed $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

log_pass "zpool export -F of an idle pool on a failed device finishes"
