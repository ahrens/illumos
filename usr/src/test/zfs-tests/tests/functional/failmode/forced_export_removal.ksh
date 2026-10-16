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
. $STF_SUITE/tests/functional/failmode/forced_export_pinned.kshlib

#
# DESCRIPTION:
#	A failmode=death pool that fails while it removes a device exports
#	cleanly, imports, and finishes the removal: whether it fails while the
#	removal copies data, so that the sync tasks that record the copies are
#	dropped, or as the removal completes, so that the sync task that
#	completes it is dropped.
#
# STRATEGY:
#	1. Fill a pool of two vdevs, and start removing one.
#	2. copying: slow the pool's I/O and the removal (one copy in flight),
#	   and once the removal has synced some copies, make every write fail
#	   (but not the probes).
#	   completing: with a file being rewritten and slow I/O, make every
#	   write fail as the removal thread enters vdev_remove_complete().
#	3. Check (with DTrace) that the failed pool dropped a removal sync task.
#	4. Export, import, wait for the removal to finish, and scrub.
#

typeset max_copy=$(get_tunable zfs_remove_max_copy_bytes)

function cleanup
{
	pin_cleanup
	set_tunable32 zfs_remove_max_copy_bytes $max_copy
}

#
# Say when the removal has synced copies, optionally make every write fail
# as it completes, and name the sync tasks that the failed pool drops.
#
function mkd # fire-at-completion
{
	cat > $PIN_D <<EOF
#pragma D option quiet
#pragma D option destructive
#pragma D option switchrate=100hz
#pragma D option strsize=2048
inline string pool = "$TESTPOOL";
int copying, fired;
BEGIN
{
	printf("ready\\n");
}
fbt::vdev_mapping_sync:entry
/!copying && stringof(args[1]->tx_pool->dp_spa->spa_name) == pool/
{
	copying = 1;
	printf("copying\\n");
}
fbt::vdev_remove_complete:entry
/$1 && !fired && stringof(args[0]->spa_name) == pool/
{
	fired = 1;
	system("$FAULT");
	printf("fired\\n");
	/* Hold the removal here while zinject runs. */
	chill(400000000);
}
fbt::dsl_sync_task_sync:entry
/args[0]->dst_pool->dp_spa->spa_exit == 2 &&
    stringof(args[0]->dst_pool->dp_spa->spa_name) == pool/
{
	printf("dropped %a\\n", (uintptr_t)args[0]->dst_syncfunc);
}
EOF
}

#
# The pool must have room for all of v2 after it's removed, so v2 is the
# smaller vdev.
#
function fill
{
	typeset -i i
	log_must mkdir -p $PIN_VD
	log_must mkfile 1g $PIN_V1
	log_must mkfile 256m $PIN_V2
	log_must zpool create -f -o failmode=death $TESTPOOL $PIN_V1 $PIN_V2
	log_must zfs create -o recordsize=128k -o compression=off \
	    $TESTPOOL/$TESTFS
	for ((i = 0; i < 4; i++)); do
		log_must dd if=/dev/urandom of=$PIN_FS/f$i bs=1024k count=64
	done
	log_must zpool sync $TESTPOOL
}

#
# While the removal copies, make every write fail, but leave the probes
# alone: a vdev that fails its probe can't be allocated from, and the
# removal can't take that (its copies' allocations "can not fail", see
# spa_vdev_copy_impl()).
#
WFAULT="zinject -d $PIN_V1 -e io -T write $TESTPOOL >/dev/null;\
    zinject -d $PIN_V2 -e io -T write $TESTPOOL >/dev/null"

function wait_for # pattern
{
	typeset -i t=180
	until grep -q "^$1" $PIN_OUT; do
		((t-- == 0)) && log_fail "never saw \"$1\""
		sleep 1
	done
}

function finish # dropped-task
{
	failmode_wait_failed $TESTPOOL
	typeset -i t=60
	until grep -q "^dropped zfs\`$1\$" $PIN_OUT; do
		((t-- == 0)) && break
		sleep 1
	done
	kill $pin_dpid >/dev/null 2>&1
	pin_dpid=""
	cat $PIN_OUT
	grep -q "^dropped zfs\`$1\$" $PIN_OUT ||
	    log_fail "the failed pool didn't drop $1"
	pin_kill_bg

	pin_export_failed
	log_must zpool import -d $PIN_VD $TESTPOOL
	log_must zpool wait -t remove $TESTPOOL
	log_must zpool sync $TESTPOOL
	log_must is_pool_removed $TESTPOOL
	log_must zpool scrub -w $TESTPOOL
	log_must check_pool_status $TESTPOOL "errors" "No known data errors"
	log_must zpool destroy $TESTPOOL
	rm -rf $PIN_VD
}

log_assert "A failmode=death pool that fails while it removes a device" \
    "exports, imports and finishes the removal"
log_onexit cleanup

log_must mkdir -p $PIN_DIR

log_note "copying"
fill
FAULT=$WFAULT
mkd 0
pin_start_d
log_must set_tunable32 zfs_remove_max_copy_bytes 1048576
pin_slow 100 $PIN_V1 $PIN_V2
log_must zpool remove $TESTPOOL $PIN_V2
wait_for copying
log_must is_pool_removing $TESTPOOL
# Failed writes are reexecuted until the pool fails; don't delay them.
log_must zinject -c all
log_must eval "$WFAULT"
log_must dd if=/dev/urandom of=$PIN_FS/dirty bs=128k count=8
finish vdev_mapping_sync
log_must set_tunable32 zfs_remove_max_copy_bytes $max_copy

#
# The copies are done by then, so the probes can fail too, which fails the
# pool sooner (v2 is gone by the time zinject runs).  A writer that keeps
# rewriting a file, with slow I/O, keeps the removal's txgs from syncing
# before zinject has run.
#
log_note "completing"
fill
FAULT=$(pin_fault_cmd $PIN_V1)
mkd 1
pin_start_d
pin_slow 100 $PIN_V1 $PIN_V2
pin_bg ksh -c "while dd if=/dev/urandom of=$PIN_FS/rewrite bs=1024k count=32 \
    conv=notrunc 2>/dev/null; do :; done"
log_must zpool remove $TESTPOOL $PIN_V2
wait_for fired
finish vdev_remove_complete_sync

log_pass "A failmode=death pool that fails while it removes a device" \
    "exports, imports and finishes the removal"
