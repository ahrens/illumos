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
#	"zpool export -F" of a suspended pool works while another command
#	sleeps on that pool holding spa_namespace_lock, and that command then
#	returns too.  "zpool reguid" waits for its sync task with the lock
#	held.  Like every command that changes the pool, it refuses to start
#	on a suspended pool, so it has to start first: the pool suspends
#	when its sync task tries to write.
#

typeset -i reguid_pid=0

function cleanup
{
	zinject -c all >/dev/null 2>&1
	pool_is_suspended $TESTPOOL && zpool clear $TESTPOOL
	if ((reguid_pid != 0)); then
		kill $reguid_pid >/dev/null 2>&1
		wait $reguid_pid
	fi
	failmode_cleanup
}

#
# Is spa_namespace_lock held?
#
function namespace_lock_held
{
	typeset held=$(echo "spa_namespace_lock::mutex" | mdb -k |
	    nawk 'NR == 2 { print $3 }')
	log_note "spa_namespace_lock owner: $held"
	[[ -n $held && $held != "-" ]]
}

log_assert "zpool export -F works while a command sleeps on the pool" \
    "holding spa_namespace_lock"
log_onexit cleanup

failmode_create_pool wait
log_must zpool sync $TESTPOOL
failmode_break_vdev

zpool reguid $TESTPOOL &
reguid_pid=$!
typeset -i tries=30
until pool_is_suspended $TESTPOOL; do
	if ((tries-- == 0)); then
		log_fail "pool didn't suspend"
	fi
	sleep 1
done
sleep 2
kill -0 $reguid_pid 2>/dev/null ||
    log_fail "zpool reguid didn't wait for the suspended pool"
log_must namespace_lock_held

#
# The injection handlers stay: "zinject -c" needs spa_namespace_lock too.  The
# export fails the pool, which lets zpool reguid return, and then waits for
# the handlers to go away; it gives up with EBUSY (see forced_export_retry).
#
run_within 60 "zpool export -fF of the suspended pool" \
    zpool export -fF $TESTPOOL
log_note "zpool export -fF returned $within_rc"

typeset -i tries=30
while kill -0 $reguid_pid 2>/dev/null; do
	if ((tries-- == 0)); then
		log_fail "zpool reguid is still waiting"
	fi
	sleep 1
done
wait $reguid_pid
log_note "zpool reguid returned $?"
reguid_pid=0

log_must zinject -c all
if poolexists $TESTPOOL; then
	log_must pool_has_failed $TESTPOOL
	log_must zpool export -fF $TESTPOOL
fi
log_mustnot poolexists $TESTPOOL

log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
log_must zpool scrub $TESTPOOL
log_must wait_scrubbed $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

log_pass "zpool export -F works while a command sleeps on the pool" \
    "holding spa_namespace_lock"
