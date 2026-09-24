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
# Copyright (c) 2025, Klara, Inc.
# Copyright 2026 Oxide Computer Company

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/failmode/failmode.kshlib

#
# DESCRIPTION:
#	With failmode=continue, ZPL operations that assign their tx with
#	DMU_TX_NOWAIT (and then dmu_tx_wait() and retry on ERESTART) fail
#	with an error while the pool is suspended, rather than blocking or
#	spinning.
#

set -A pids

function cleanup
{
	zinject -c all >/dev/null 2>&1
	pool_is_suspended $TESTPOOL && zpool clear $TESTPOOL
	for pid in ${pids[@]}; do
		kill -9 $pid 2>/dev/null
	done
	failmode_cleanup
}

log_assert "DMU_TX_NOWAIT operations return when pool suspends with " \
    "failmode=continue"
log_onexit cleanup

failmode_create_pool continue
typeset dir=/$TESTPOOL/$TESTFS
log_must touch $dir/old
failmode_suspend_pool

touch $dir/new &
pids[0]=$!
mkdir $dir/newdir &
pids[1]=$!
mv $dir/old $dir/moved &
pids[2]=$!

typeset -i i
set -A blocked
for ((i = 0; i < ${#pids[@]}; i++)); do
	proc_is_blocked ${pids[$i]}
	blocked[$i]=$?
done

failmode_resume_pool

set -A rc
for ((i = 0; i < ${#pids[@]}; i++)); do
	wait ${pids[$i]}
	rc[$i]=$?
done
set -A pids

for ((i = 0; i < ${#rc[@]}; i++)); do
	((blocked[$i] == 0)) && log_fail "op $i blocked while pool suspended"
	((blocked[$i] == 2)) && \
	    log_fail "op $i spun on the CPU while pool suspended"
	log_must test ${rc[$i]} -ne 0
done

log_pass "DMU_TX_NOWAIT operations return when pool suspends with " \
    "failmode=continue"
