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
#	Once a pool has failed, the I/O that it no longer does is not reported
#	one ereport at a time: writes to it and syncs of it after it has
#	failed post no more ereports.
#

typeset FS=/$TESTPOOL/$TESTFS

function ereports
{
	fmdump -e 2>/dev/null | grep -c "ereport.fs.zfs"
}

log_assert "A failed pool posts no ereport for each I/O it drops"
log_onexit failmode_cleanup

failmode_create_pool death
failmode_break_vdev
log_must dd if=/dev/urandom of=$FS/dirty bs=128k count=8
failmode_wait_failed $TESTPOOL

# Let the ereports from before the failure arrive.
sleep 10
typeset -i before=$(ereports)

for ((i = 0; i < 10; i++)); do
	dd if=/dev/urandom of=$FS/after.$i bs=128k count=64 >/dev/null 2>&1
	zpool sync $TESTPOOL >/dev/null 2>&1
done
sleep 10
typeset -i after=$(ereports)
log_note "ereports: $before before, $after after"
((after == before)) ||
    log_fail "the failed pool posted $((after - before)) more ereports"

log_must zinject -c all
log_must zpool export $TESTPOOL

log_pass "A failed pool posts no ereport for each I/O it drops"
