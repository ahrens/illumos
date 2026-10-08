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
#	If the cache flush after a ZIL block write fails, the block may not
#	be on stable storage, so zil_commit() must not report it as committed.
#	It has to fall back to waiting for the txg to sync, which the
#	zil-commit-io-error probe marks.
#
# STRATEGY:
#	1. Create a pool with sync=always, so that every write commits the ZIL.
#	2. Write without any fault injected and check that the ZIL never falls
#	   back to a txg sync.
#	3. Make all cache flushes to the vdev fail ("zinject -T ioctl").
#	4. Write again and check that each commit falls back to a txg sync.
#

verify_runnable "global"

function cleanup
{
	failmode_cleanup
}

#
# Write $1 sync blocks to the test file system and print how many ZIL commits
# fell back to a txg sync because of an I/O error.
#
function count_fallbacks # nwrites
{
	dtrace -q -n 'sdt:::zil-commit-io-error { n++; }' \
	    -n 'END { printf("%d\n", n); }' \
	    -c "dd if=/dev/urandom of=/$TESTPOOL/$TESTFS/file bs=8k count=$1" \
	    2>/dev/null
}

log_assert "A ZIL commit whose cache flush fails falls back to a txg sync"
log_onexit cleanup

failmode_create_pool wait
log_must zfs set sync=always $TESTPOOL/$TESTFS

typeset n=$(count_fallbacks 2)
log_note "fallbacks without injection: $n"
[[ $n == 0 ]] || log_fail "ZIL fell back without an error injected ($n)"

#
# Keep the number of failed flushes small: each one posts an ereport, and too
# many would get the vdev faulted.
#
log_must zinject -d $FAILMODE_VDEV -e io -T ioctl $TESTPOOL
n=$(count_fallbacks 2)
log_must zinject -c all
log_note "fallbacks with failing flushes: $n"
[[ -n $n ]] && ((n >= 2)) || \
    log_fail "ZIL reported commits with failed flushes as done ($n)"

log_pass "A ZIL commit whose cache flush fails falls back to a txg sync"
