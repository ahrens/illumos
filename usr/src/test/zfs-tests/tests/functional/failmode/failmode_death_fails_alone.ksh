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
#	A failmode=death pool whose writes fail fails instead of suspending,
#	and nothing else is affected:
#	- the pool is not suspended, "zpool clear" can't revive it, and
#	  "zpool destroy" refuses it, saying to use "zpool export -f"
#	- writes, syncs and administrative commands on it return
#	- other pools carry on as usual
#	- nothing more reaches its disks, so they stay at the last txg that
#	  synced before it failed
#	- "zpool export" removes it, and it can be imported again from what
#	  is on its disks
#

typeset OTHER_DIR=$TEST_BASE_DIR/failmode_other_dir
typeset FS=/$TESTPOOL/$TESTFS

function cleanup
{
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	if ! poolexists $TESTPOOL1 && [[ -f $OTHER_DIR/vdev ]]; then
		zpool import -d $OTHER_DIR $TESTPOOL1 >/dev/null 2>&1 &&
		    destroy_pool $TESTPOOL1
	fi
	rm -rf $OTHER_DIR
	failmode_cleanup
}

log_assert "A failmode=death pool fails alone and can be exported"
log_onexit cleanup

log_must mkdir -p $OTHER_DIR
log_must mkfile $MINVDEVSIZE $OTHER_DIR/vdev
log_must zpool create -f $TESTPOOL1 $OTHER_DIR/vdev

failmode_create_pool death
log_must dd if=/dev/urandom of=$FS/before bs=128k count=8
sync_pool $TESTPOOL
typeset before=$(digest -a sha256 $FS/before)

failmode_break_vdev
log_must dd if=/dev/urandom of=$FS/dirty bs=128k count=8
failmode_wait_failed $TESTPOOL

if pool_is_suspended $TESTPOOL; then
	log_fail "failed pool is suspended"
fi
typeset health=$(zpool list -H -o health $TESTPOOL)
[[ $health == FAILED ]] || log_fail "failed pool's health is $health"
zpool status $TESTPOOL | grep -q "^ *state: FAILED" ||
    log_fail "zpool status doesn't show the pool as FAILED"
log_mustnot zpool clear $TESTPOOL
log_must pool_has_failed $TESTPOOL

# It can't be destroyed either, and zpool destroy says what to do instead.
typeset err
err=$(zpool destroy -f $TESTPOOL 2>&1) &&
    log_fail "zpool destroy of the failed pool succeeded"
log_note "zpool destroy: $err"
[[ $err == *"use 'zpool export -f'"* ]] ||
    log_fail "zpool destroy didn't say to use zpool export -f"
log_must poolexists $TESTPOOL
log_must pool_has_failed $TESTPOOL

# Let any writes that were already in flight when it failed land.
sleep 2
typeset d1=$(vdev_digest $FAILMODE_VDEV)

# Writes, syncs and administration of the failed pool return.
run_within 30 "write to the failed pool" \
    dd if=/dev/urandom of=$FS/after bs=128k count=8
run_within 30 "zpool sync of the failed pool" zpool sync $TESTPOOL
run_within 30 "zfs snapshot in the failed pool" zfs snapshot $TESTPOOL@snap
run_within 30 "zfs set in the failed pool" zfs set user:prop=1 $TESTPOOL
run_within 30 "zpool status of the failed pool" zpool status $TESTPOOL
run_within 30 "zpool get of the failed pool" zpool get all $TESTPOOL

# The other pool is unaffected.
run_within 30 "zfs create in another pool" zfs create $TESTPOOL1/fs
log_must test $within_rc -eq 0
run_within 30 "write to another pool" \
    dd if=/dev/urandom of=/$TESTPOOL1/fs/file bs=128k count=8
log_must test $within_rc -eq 0
run_within 30 "zpool sync of another pool" zpool sync $TESTPOOL1
log_must test $within_rc -eq 0
run_within 30 "zpool export of another pool" zpool export $TESTPOOL1
log_must test $within_rc -eq 0
run_within 30 "zpool import of another pool" \
    zpool import -d $OTHER_DIR $TESTPOOL1
log_must test $within_rc -eq 0

# Nothing reached the failed pool's disk, even after more txgs.
sleep 10
typeset d2=$(vdev_digest $FAILMODE_VDEV)
[[ $d1 == $d2 ]] || log_fail "the failed pool wrote to its disk"

#
# The injection handlers hold the pool, so clear them first.  Nothing can
# reach the disk any more, injected or not.
#
log_must zinject -c all
run_within 60 "zpool export of the failed pool" zpool export $TESTPOOL
log_must test $within_rc -eq 0
log_mustnot poolexists $TESTPOOL
typeset d3=$(vdev_digest $FAILMODE_VDEV)
[[ $d1 == $d3 ]] || log_fail "exporting the failed pool wrote to its disk"

# The disk holds the pool as of the last txg that synced.
log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
log_must test "$(digest -a sha256 $FS/before)" == "$before"
log_mustnot test -e $FS/after
log_mustnot test -e $FS/dirty
log_must zpool scrub $TESTPOOL
log_must wait_scrubbed $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

log_pass "A failmode=death pool fails alone and can be exported"
