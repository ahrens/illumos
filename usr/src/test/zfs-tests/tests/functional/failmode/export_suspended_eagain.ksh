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
#	"zpool export" and "zpool export -f" of a suspended pool fail at once,
#	saying that the pool is suspended and that -F would discard its
#	unsynced changes, and leave the pool as it was, so that it can resume.
#	This holds both with its file systems unmounted (the kernel refuses
#	the export) and with them mounted (zpool must not try to unmount
#	them, which would wait for the suspended pool).
#

typeset ERR=$TEST_BASE_DIR/export_suspended_eagain.err
typeset -i dirty_pid=0

function cleanup
{
	zinject -c all >/dev/null 2>&1
	pool_is_suspended $TESTPOOL && zpool clear $TESTPOOL
	if ((dirty_pid != 0)); then
		kill $dirty_pid >/dev/null 2>&1
		wait $dirty_pid
	fi
	failmode_cleanup
	rm -f $ERR
}

log_assert "zpool export of a suspended pool fails at once"
log_onexit cleanup

for mounted in false true; do
	log_note "file systems mounted: $mounted"
	failmode_create_pool wait
	if ! $mounted; then
		log_must zfs unmount $TESTPOOL/$TESTFS
		log_must zfs unmount $TESTPOOL
	fi
	failmode_break_vdev
	zfs set user:dirty=1 $TESTPOOL &
	dirty_pid=$!
	typeset -i tries=30
	until pool_is_suspended $TESTPOOL; do
		if ((tries-- == 0)); then
			log_fail "pool didn't suspend"
		fi
		sleep 1
	done

	for flags in "" "-f"; do
		run_within 5 "zpool export $flags of the suspended pool" \
		    ksh -c "zpool export $flags $TESTPOOL 2>$ERR"
		log_mustnot test $within_rc -eq 0
		log_note "$(cat $ERR)"
		log_must grep -q "pool is suspended; use '-F'" $ERR
		log_must poolexists $TESTPOOL
		log_mustnot pool_has_failed $TESTPOOL
		# Read mnttab directly; "zfs get" may wait for the pool.
		if $mounted && ! nawk -v fs=$TESTPOOL/$TESTFS \
		    '$1 == fs { found = 1 } END { exit !found }' /etc/mnttab
		then
			log_fail "$TESTPOOL/$TESTFS was unmounted"
		fi
	done

	failmode_resume_pool
	log_must wait $dirty_pid
	dirty_pid=0
	failmode_cleanup
done

log_pass "zpool export of a suspended pool fails at once"
