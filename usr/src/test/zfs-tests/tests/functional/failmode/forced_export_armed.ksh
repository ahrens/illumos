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
#	"zpool export -F" of a pool that is healthy but slow waits for it to
#	sync, as a normal export does.  If the pool suspends while the export
#	is waiting, it fails at once (even though it has failmode=wait), and
#	the export finishes.
#

typeset -i dirty_pid=0 export_pid=0

function cleanup
{
	zinject -c all >/dev/null 2>&1
	pool_is_suspended $TESTPOOL && zpool clear $TESTPOOL
	for pid in $dirty_pid $export_pid; do
		((pid != 0)) || continue
		kill $pid >/dev/null 2>&1
		wait $pid
	done
	failmode_cleanup
}

log_assert "A pool armed by zpool export -F fails when it suspends"
log_onexit cleanup

failmode_create_pool wait
log_must zfs unmount $TESTPOOL/$TESTFS
log_must zfs unmount $TESTPOOL

# Slow the pool down, so that the export has to wait for it.
log_must zinject -d $FAILMODE_VDEV -D 1000:1 $TESTPOOL
zfs set user:dirty=1 $TESTPOOL &
dirty_pid=$!
zpool export -F $TESTPOOL &
export_pid=$!
sleep 3
kill -0 $export_pid 2>/dev/null || log_fail "export didn't wait for the pool"
log_mustnot pool_has_failed $TESTPOOL

# Now break it.  It suspends, and fails.
failmode_break_vdev
failmode_wait_failed $TESTPOOL

#
# The injection handlers hold the pool, which keeps it from being exported;
# the export waits for them to go away.
#
log_must zinject -c all
typeset -i tries=60
while kill -0 $export_pid 2>/dev/null; do
	if ((tries-- == 0)); then
		log_fail "zpool export -F did not finish"
	fi
	sleep 1
done
log_must wait $export_pid
export_pid=0
log_mustnot poolexists $TESTPOOL
wait $dirty_pid
dirty_pid=0

log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
log_must zpool scrub $TESTPOOL
log_must wait_scrubbed $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

log_pass "A pool armed by zpool export -F fails when it suspends"
