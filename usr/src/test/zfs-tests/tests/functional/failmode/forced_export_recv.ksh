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
#	Receives survive a failmode=death pool failing mid-stream:
#	- A receive into the failing pool fails; after re-import, the
#	  partial receive resumes from its token (or is aborted and done
#	  again) and matches the source.
#	- A healthy pool receiving the failing pool's send fails cleanly and
#	  stays healthy; after the failed pool's re-import, the receive
#	  resumes and matches.
#	- A pool that fails in the txg that starts a receive
#	  (dmu_recv_begin_sync()) exports, and imports without the new file
#	  system.
#	- A pool that fails in the txg that finishes a receive
#	  (dmu_recv_end_sync()), of a new file system or of an incremental
#	  into a mounted one, imports without the received snapshot, and the
#	  receive resumes (or is done again) and matches.
#
# STRATEGY:
#	Send through a pipe limited to 20MB/s, fail the pool after a few
#	seconds (for the last cases, as dmu_recv_begin_sync() or
#	dmu_recv_end_sync() runs, from DTrace), export -f within 60 seconds,
#	import, scrub, and finish the receive.
#

typeset spid=""
typeset SRC=$PIN_POOL2/src

function cleanup
{
	pkill -9 -f "[t]hrottle.py" >/dev/null 2>&1
	[[ -n $spid ]] && kill -9 $spid >/dev/null 2>&1
	pin_cleanup
}

function wait_pipe
{
	typeset -i t=60
	while kill -0 $spid 2>/dev/null; do
		((t-- == 0)) && log_fail "the send and receive are" \
		    "still running"
		sleep 1
	done
	wait $spid
	spid=""
	log_note "recv: $(cat $PIN_DIR/recv.err) exit $(cat $PIN_DIR/recv.rc)"
	[[ $(cat $PIN_DIR/recv.rc) != 0 ]] || log_fail "the receive succeeded"
}

function next_case
{
	log_must zpool destroy $TESTPOOL
	log_must zpool destroy $PIN_POOL2
	rm -rf $PIN_VD $PIN_SLOW
	pin_mkpools
}

log_assert "Receives survive a failmode=death pool failing mid-stream"
log_onexit cleanup

pin_mkthrottle
pin_mkpools

# Into the failing pool.
pin_fill $SRC
(zfs send $SRC@s | python $PIN_THROTTLE 20 |
    (zfs recv -s $TESTPOOL/dst 2>$PIN_DIR/recv.err;
    echo $? > $PIN_DIR/recv.rc)) &
spid=$!
sleep 4
pin_fail_now
wait_pipe
pin_export_failed
pin_reimport
pin_finish_recv $SRC $SRC@s $TESTPOOL/dst

# From the failing pool.
next_case
pin_fill $TESTPOOL/$TESTFS
log_must zpool export $TESTPOOL
log_must zpool import -d $PIN_VD $TESTPOOL
(zfs send $TESTPOOL/$TESTFS@s 2>/dev/null | python $PIN_THROTTLE 20 |
    (zfs recv -s $PIN_POOL2/dst 2>$PIN_DIR/recv.err;
    echo $? > $PIN_DIR/recv.rc)) &
spid=$!
sleep 4
pin_fail_now
wait_pipe
log_must eval "zpool status -x $PIN_POOL2 | grep 'is healthy'"
pin_export_failed
pin_reimport
typeset tok=$(zfs get -H -o value receive_resume_token $PIN_POOL2/dst)
[[ -n $tok && $tok != - ]] || log_fail "no resume token on $PIN_POOL2/dst"
pin_finish_recv $TESTPOOL/$TESTFS $TESTPOOL/$TESTFS@s $PIN_POOL2/dst
log_must zpool scrub -w $PIN_POOL2
log_must check_pool_status $PIN_POOL2 "errors" "No known data errors"

#
# Fail the pool in the txg of <sync-func> (dmu_recv_begin_sync() or
# dmu_recv_end_sync()) while <send> | zfs recv -s <fs> runs, then export and
# import.
#
function fail_in_recv_sync # sync-func send-args fs
{
	FAULT=$(pin_fault_cmd $PIN_V1 $PIN_V2)
	{
		pin_d_header
		cat <<EOF
fbt::$1:entry
/!fired && stringof(args[1]->tx_pool->dp_spa->spa_name) == pool/
{
	fired = 1; t_fire = timestamp;
	system("$FAULT");
	printf("fired in $1, txg %d\\n", args[1]->tx_txg);
}
fbt::spa_fail:entry
/fired && stringof(args[0]->spa_name) == pool/
{
	printf("spa_fail %d ms after firing\\n",
	    (timestamp - t_fire) / 1000000);
	exit(0);
}
EOF
	} > $PIN_D
	pin_start_d
	pin_slow 500 $PIN_V1 $PIN_V2
	zfs send $2 | zfs recv -s $3
	log_note "zfs recv exited $?"
	failmode_wait_failed $TESTPOOL
	typeset -i t=30
	while kill -0 $pin_dpid 2>/dev/null; do
		((t-- == 0)) && break
		sleep 1
	done
	pin_dpid=""
	cat $PIN_OUT
	grep -q "^fired" $PIN_OUT || log_fail "$1() didn't run"
	pin_export_failed
	pin_reimport
	log_note "after import: $(zfs list -H -t all -o name -r $TESTPOOL)"
}

# The received snapshot isn't there: that txg never committed.
function fail_in_recv_end # send-args fs snap
{
	fail_in_recv_sync dmu_recv_end_sync "$1" $2
	log_mustnot snapexists $2@$3
}

# In the txg of dmu_recv_begin_sync().  The receive fails, and the dataset
# that the sync task set up mustn't keep the pool from being exported.
next_case
pin_fill $SRC
fail_in_recv_sync dmu_recv_begin_sync $SRC@s $TESTPOOL/dst
log_mustnot datasetexists $TESTPOOL/dst
pin_finish_recv $SRC $SRC@s $TESTPOOL/dst

# In the txg of dmu_recv_end_sync(), receiving a new file system.
next_case
pin_fill $SRC
fail_in_recv_end $SRC@s $TESTPOOL/dst s
pin_finish_recv $SRC $SRC@s $TESTPOOL/dst

# The same, receiving an incremental into a mounted file system (an online
# receive, which suspends and resumes the file system around the end).
next_case
pin_fill $SRC
log_must eval "zfs send $SRC@s | zfs recv $TESTPOOL/dst"
log_must dd if=/dev/urandom of=/$SRC/f8 bs=1024k count=32
log_must zfs snapshot $SRC@s2
log_must ismounted $TESTPOOL/dst
fail_in_recv_end "-i @s $SRC@s2" $TESTPOOL/dst s2
# Reading it mustn't change it, or the incremental can't resume.
log_must zfs set atime=off $TESTPOOL/dst
pin_same $SRC/.zfs/snapshot/s $TESTPOOL/dst
pin_finish_recv $SRC "-i @s $SRC@s2" $TESTPOOL/dst

log_pass "Receives survive a failmode=death pool failing mid-stream"
