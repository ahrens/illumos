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
#	Writes that fail until the pool suspends, and succeed once it resumes,
#	aren't permanent errors: "zpool status -v" doesn't list them (before
#	any scrub), and the data reads back intact (failmode=wait or
#	continue).  zio_done() used to log a write's error before deciding to
#	reexecute it.
#
# STRATEGY:
#	For failmode=wait and continue:
#	1. Create a pool on a file vdev
#	2. Make every write to the vdev fail, leaving the probes alone, so
#	   that the writes are retried until the pool suspends
#	3. Write a small file (it fits in the open txg); the pool must
#	   suspend within 30 seconds
#	4. Clear the injection; zpool clear resumes the pool and the writes
#	   complete
#	5. zpool status -v reports no known data errors (the resilver of
#	   the failed writes is held until then: a finished scan drops the
#	   error log)
#	6. After an export and import, the file reads back intact
#

verify_runnable "global"

typeset src=$TEST_BASE_DIR/transient_src

function cleanup
{
	set_tunable32 zfs_scan_suspend_progress 0
	failmode_cleanup
	rm -f $src
}

log_assert "Writes retried across a suspend aren't permanent errors"
log_onexit cleanup

log_must dd if=/dev/urandom of=$src bs=128k count=8
typeset cksum=$(sha256digest $src)

for mode in wait continue; do
	log_note "failmode=$mode"
	failmode_create_pool $mode
	typeset fs=$(get_prop mountpoint $TESTPOOL/$TESTFS)
	sync_pool $TESTPOOL

	log_must zinject -d $FAILMODE_VDEV -e io -T write $TESTPOOL
	# A write blocks once the pool suspends, so it must finish first.
	log_must dd if=$src of=$fs/data bs=128k
	log_note "waiting for $TESTPOOL to suspend"
	typeset -i tries=30
	until pool_is_suspended $TESTPOOL; do
		if ((tries-- == 0)); then
			log_fail "$TESTPOOL didn't suspend"
		fi
		sleep 1
	done

	# zpool clear resilvers the failed writes, and a finished scan drops
	# the error log, so hold the resilver until the log has been checked.
	log_must set_tunable32 zfs_scan_suspend_progress 1
	failmode_resume_pool
	sync_pool $TESTPOOL
	log_must zpool status -v $TESTPOOL
	log_must check_pool_status $TESTPOOL "errors" "No known data errors"
	log_must set_tunable32 zfs_scan_suspend_progress 0

	log_must zpool export $TESTPOOL
	log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
	log_must test "$cksum" = "$(sha256digest $fs/data)"
	log_must check_pool_status $TESTPOOL "errors" "No known data errors"
	failmode_cleanup
done

log_pass "Writes retried across a suspend aren't permanent errors"
