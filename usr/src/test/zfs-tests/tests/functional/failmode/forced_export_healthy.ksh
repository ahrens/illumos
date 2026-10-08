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
#	"zpool export -F" of a healthy pool arms it for forced exit, but it
#	never suspends, so it does not fail: the export syncs everything that
#	was written before it, as a normal export does.
#

typeset FS=/$TESTPOOL/$TESTFS

function cleanup
{
	failmode_cleanup
}

log_assert "zpool export -F of a healthy pool loses nothing"
log_onexit cleanup

failmode_create_pool wait
log_must zfs set sync=disabled $TESTPOOL/$TESTFS
log_must dd if=/dev/urandom of=$FS/file bs=128k count=64
typeset sum=$(digest -a sha256 $FS/file)
log_must zfs set user:last=1 $TESTPOOL

run_within 60 "zpool export -F of a healthy pool" zpool export -F $TESTPOOL
log_must test $within_rc -eq 0
log_mustnot poolexists $TESTPOOL

log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
log_mustnot pool_has_failed $TESTPOOL
log_must test "$(digest -a sha256 $FS/file)" == "$sum"
log_must test "$(get_prop user:last $TESTPOOL)" == "1"
log_must zpool scrub $TESTPOOL
log_must wait_scrubbed $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

# The pool works as usual once it has been imported again.
log_must dd if=/dev/urandom of=$FS/file2 bs=128k count=8
sync_pool $TESTPOOL

log_pass "zpool export -F of a healthy pool loses nothing"
