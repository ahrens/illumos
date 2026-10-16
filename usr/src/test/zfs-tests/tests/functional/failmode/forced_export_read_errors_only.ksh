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
#	"zpool export -F" of a pool whose device fails only its reads, and
#	that nothing is writing to, fails it and finishes.
#

log_assert "zpool export -F of a pool that only gets read errors finishes"
log_onexit failmode_cleanup

failmode_create_pool wait
log_must dd if=/dev/urandom of=/$TESTPOOL/$TESTFS/file bs=128k count=64
log_must zpool export $TESTPOOL
log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
log_must zinject -d $FAILMODE_VDEV -e io -T read $TESTPOOL

# Reading the file fails, and doesn't hang.
run_within 60 "reading from the pool" \
    dd if=/$TESTPOOL/$TESTFS/file of=/dev/null bs=128k

log_must zinject -c all
run_within 60 "zpool export -F of the pool" zpool export -F $TESTPOOL
log_must test $within_rc -eq 0
log_mustnot poolexists $TESTPOOL

log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
log_must zpool scrub $TESTPOOL
log_must wait_scrubbed $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

log_pass "zpool export -F of a pool that only gets read errors finishes"
