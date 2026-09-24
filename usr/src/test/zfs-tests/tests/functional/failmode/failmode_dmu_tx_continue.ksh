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

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/failmode/failmode.kshlib

#
# DESCRIPTION:
#	With failmode=continue, a write that needs a new tx (dmu_tx_assign()
#	with DMU_TX_WAIT) fails with an error while the pool is suspended,
#	rather than blocking.
#

typeset -i dd_pid=0

function cleanup
{
	zinject -c all >/dev/null 2>&1
	pool_is_suspended $TESTPOOL && zpool clear $TESTPOOL
	((dd_pid > 0)) && kill -9 $dd_pid
	failmode_cleanup
}

log_assert "dmu_tx_assign() returns when pool suspends with failmode=continue"
log_onexit cleanup

failmode_create_pool continue

#
# Create the file before suspending, and don't truncate it, so that dd only
# needs txs for its writes (zfs_write() assigns with DMU_TX_WAIT). Creating
# files is covered by the failmode_nowait tests.
#
log_must touch /$TESTPOOL/$TESTFS/file
failmode_suspend_pool

dd if=/dev/urandom of=/$TESTPOOL/$TESTFS/file bs=128k count=64 conv=notrunc &
dd_pid=$!

proc_is_blocked $dd_pid
typeset -i blocked=$?

failmode_resume_pool

wait $dd_pid
typeset -i rc=$?
dd_pid=0

((blocked == 0)) && log_fail "dd blocked while pool suspended"
((blocked == 2)) && log_fail "dd spun on the CPU while pool suspended"
log_must test $rc -ne 0

log_pass "dmu_tx_assign() returns when pool suspends with failmode=continue"
