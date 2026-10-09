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
#	While one pool is suspended, and while "zpool export -F" fails it and
#	exports it, commands on another pool each finish within 5 seconds:
#	zpool list, zpool status, opening one of its volumes, and exporting
#	and importing it.
#
# STRATEGY:
#	1. Create a second pool, with a volume, and suspend the first.
#	2. Run the commands against the second pool.
#	3. Start "zpool export -fF" of the first pool with its injection
#	   handlers still registered.  They hold the pool, so the export
#	   fails it at once and then waits for them, and gives up with EBUSY
#	   after about 20 seconds (see forced_export_retry).  Run the
#	   commands again, over and over, until the export returns.
#	4. Remove the handlers, export the first pool, and run the commands
#	   once more.
#

typeset OTHER_DIR=$TEST_BASE_DIR/fe_other_pools_dir
typeset OTHER_VOL=/dev/zvol/rdsk/$TESTPOOL1/vol
typeset -i export_pid=0

function cleanup
{
	if ((export_pid != 0)); then
		kill $export_pid >/dev/null 2>&1
		wait $export_pid
	fi
	zinject -c all >/dev/null 2>&1
	pool_is_suspended $TESTPOOL && zpool clear $TESTPOOL
	if ! poolexists $TESTPOOL1 && [[ -f $OTHER_DIR/vdev ]]; then
		zpool import -d $OTHER_DIR $TESTPOOL1 >/dev/null 2>&1
	fi
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	rm -rf $OTHER_DIR
	failmode_cleanup
}

#
# Run the commands against the other pool; each must succeed within 5
# seconds.
#
function check_other_pool # when
{
	# The volume's minor comes back a moment after an import.
	typeset -i tries=10
	until [[ -e $OTHER_VOL ]]; do
		if ((tries-- == 0)); then
			log_fail "$OTHER_VOL didn't come back after the import"
		fi
		sleep 1
	done

	run_within 5 "$1: zpool list" zpool list
	log_must test $within_rc -eq 0
	run_within 5 "$1: zpool status of another pool" \
	    zpool status $TESTPOOL1
	log_must test $within_rc -eq 0
	run_within 5 "$1: open of another pool's volume" \
	    dd if=$OTHER_VOL of=/dev/null bs=128k count=1
	log_must test $within_rc -eq 0
	run_within 5 "$1: zpool export of another pool" zpool export $TESTPOOL1
	log_must test $within_rc -eq 0
	run_within 5 "$1: zpool import of another pool" \
	    zpool import -d $OTHER_DIR $TESTPOOL1
	log_must test $within_rc -eq 0
}

log_assert "Commands on another pool finish while a pool is suspended and" \
    "while it exits"
log_onexit cleanup

log_must mkdir -p $OTHER_DIR
log_must mkfile $MINVDEVSIZE $OTHER_DIR/vdev
log_must zpool create -f $TESTPOOL1 $OTHER_DIR/vdev
log_must zfs create -V 16m $TESTPOOL1/vol

failmode_create_pool wait
failmode_suspend_pool

check_other_pool "suspended"

zpool export -fF $TESTPOOL >/dev/null 2>&1 &
export_pid=$!
typeset -i rounds=0 failed_seen=0
while kill -0 $export_pid 2>/dev/null; do
	pool_has_failed $TESTPOOL && failed_seen=1
	check_other_pool "failing"
	((rounds++))
done
wait $export_pid
log_note "zpool export -fF of the held pool returned $?" \
    "after $rounds rounds"
export_pid=0
((failed_seen == 1)) || log_fail "the pool didn't fail during the export"
((rounds >= 2)) || log_fail "only $rounds rounds ran during the export"

log_must zinject -c all
run_within 60 "zpool export -fF once nothing holds the pool" \
    zpool export -fF $TESTPOOL
log_must test $within_rc -eq 0
log_mustnot poolexists $TESTPOOL

check_other_pool "after the export"

log_pass "Commands on another pool finish while a pool is suspended and" \
    "while it exits"
