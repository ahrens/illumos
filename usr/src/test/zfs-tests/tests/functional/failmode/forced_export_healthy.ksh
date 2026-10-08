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
#	"zpool export -F" of a healthy pool fails it, rather than waiting for
#	it to sync: what had synced is kept, and so is what was written
#	synchronously, which the intent log replays at the next import, but
#	the rest of what hadn't synced is lost.
#
# STRATEGY:
#	1. Keep txgs from syncing on their own, write a file, and sync it.
#	2. Write a file synchronously, and then one asynchronously.
#	3. zpool export -F, which must fail the pool and export it at once.
#	4. Import the pool: the first two files are there, the last isn't.
#

typeset FS=/$TESTPOOL/$TESTFS
typeset -i txg_timeout=$(get_tunable zfs_txg_timeout)

function cleanup
{
	set_tunable32 zfs_txg_timeout $txg_timeout
	failmode_cleanup
}

log_assert "zpool export -F of a healthy pool discards what hadn't synced"
log_onexit cleanup

failmode_create_pool wait
log_must set_tunable32 zfs_txg_timeout 3600
log_must dd if=/dev/urandom of=$FS/synced bs=128k count=64
typeset synced=$(digest -a sha256 $FS/synced)
log_must zfs set user:before=1 $TESTPOOL
sync_pool $TESTPOOL

#
# The asynchronous write comes last: a synchronous write commits every
# file creation that came before it to the intent log.
#
log_must dd if=/dev/urandom of=$FS/logged bs=128k count=8 oflag=sync
typeset logged=$(digest -a sha256 $FS/logged)
log_must dd if=/dev/urandom of=$FS/unsynced bs=128k count=8

run_within 60 "zpool export -F of a healthy pool" zpool export -F $TESTPOOL
log_must test $within_rc -eq 0
log_mustnot poolexists $TESTPOOL
log_must set_tunable32 zfs_txg_timeout $txg_timeout

log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
log_mustnot pool_has_failed $TESTPOOL
log_must test "$(digest -a sha256 $FS/synced)" == "$synced"
log_must test "$(get_prop user:before $TESTPOOL)" == "1"
log_must test "$(digest -a sha256 $FS/logged)" == "$logged"
log_mustnot test -e $FS/unsynced
log_must zpool scrub $TESTPOOL
log_must wait_scrubbed $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

# The pool works as usual once it has been imported again.
log_must dd if=/dev/urandom of=$FS/file2 bs=128k count=8
sync_pool $TESTPOOL

log_pass "zpool export -F of a healthy pool discards what hadn't synced"
