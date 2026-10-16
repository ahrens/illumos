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
. $STF_SUITE/tests/functional/failmode/forced_export_pinned.kshlib

#
# DESCRIPTION:
#	A send from a failmode=death pool that fails mid-stream fails with an
#	error, and the pool exports.  If the reader has stopped, so that the
#	send is blocked writing to it, "zpool export -f" wakes the send, which
#	fails rather than being killed, and the pool exports with the reader
#	still stopped.
#
# STRATEGY:
#	1. Send a snapshot, with a cold cache, to a reader that takes 20MB/s.
#	2. Fail the pool.  The send exits non-zero; export -f succeeds within
#	   60 seconds.  Import, scrub, and send the snapshot again.
#	3. Do it again with the reader stopped (SIGSTOP) before the failure.
#	   export -f succeeds within 60 seconds, and the send exits 1.
#

typeset spid=""

function cleanup
{
	pkill -CONT -f "[t]hrottle.py" >/dev/null 2>&1
	pkill -9 -f "[t]hrottle.py" >/dev/null 2>&1
	[[ -n $spid ]] && kill -9 $spid >/dev/null 2>&1
	pin_cleanup
}

# Wait for the pipeline started in the background to end.
function wait_send
{
	typeset -i t=60
	while kill -0 $spid 2>/dev/null; do
		((t-- == 0)) && log_fail "the send is still running"
		sleep 1
	done
	wait $spid
	spid=""
	log_note "send: $(cat $PIN_DIR/send.err) exit $(cat $PIN_DIR/send.rc)"
}

function start_send
{
	log_must zpool export $TESTPOOL
	log_must zpool import -d $PIN_VD $TESTPOOL
	rm -f $PIN_DIR/send.rc
	( (zfs send $TESTPOOL/$TESTFS@s 2>$PIN_DIR/send.err;
	    echo $? > $PIN_DIR/send.rc) | python $PIN_THROTTLE 20 >/dev/null) &
	spid=$!
	sleep 3
	kill -0 $spid 2>/dev/null || log_fail "the send ended too soon"
}

log_assert "A send from a failmode=death pool that fails mid-stream fails," \
    "and the pool exports"
log_onexit cleanup

pin_mkthrottle

# A live reader.
pin_mkpools
pin_fill $TESTPOOL/$TESTFS
start_send
pin_fail_now
wait_send
[[ $(cat $PIN_DIR/send.rc) != 0 ]] || log_fail "the send succeeded"
pin_export_failed
pin_reimport
log_must eval "zfs send $TESTPOOL/$TESTFS@s >/dev/null"
log_must zpool destroy $TESTPOOL
log_must zpool destroy $PIN_POOL2
rm -rf $PIN_VD $PIN_SLOW

# A stopped reader.
pin_mkpools
pin_fill $TESTPOOL/$TESTFS
start_send
log_must pkill -STOP -f "[t]hrottle.py"
sleep 2
pin_fail_now
pin_export_failed
typeset -i t=30
while [[ ! -s $PIN_DIR/send.rc ]]; do
	((t-- == 0)) && log_fail "the send is still blocked"
	sleep 1
done
[[ $(cat $PIN_DIR/send.rc) == 1 ]] || log_fail "the send exited" \
    "$(cat $PIN_DIR/send.rc), not 1"
log_must pkill -9 -f "[t]hrottle.py"
wait_send
pin_reimport
log_must eval "zfs send $TESTPOOL/$TESTFS@s >/dev/null"

log_pass "A send from a failmode=death pool that fails mid-stream fails," \
    "and the pool exports"
