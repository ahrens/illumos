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
#	A write that fails to allocate just before its pool fails is written
#	into the fence once the pool has failed, even if it has no
#	reexecutions left (zio_reexecute_max).  It must not be left as a
#	hole, which would read back as zeros instead of failing.
#
# STRATEGY:
#	1. Set zio_reexecute_max to 0, so that no write has a reexecution
#	   left, and make MMP fail a pool once none of its MMP writes has
#	   succeeded for 200 ms, the least it allows.
#	2. Create a failmode=death pool with multihost=on, and write a file
#	   without syncing it.
#	3. Mark the pool's only vdev unwritable (vdev_cant_write, with mdb),
#	   so that every allocation fails with ENOSPC and MMP stops writing,
#	   and sync the pool.
#	4. A DTrace program holds (chill()) the first block of the file whose
#	   allocation fails, after the failure and before the block completes,
#	   for 480 ms, while MMP fails the pool.  MMP's last write was before
#	   the vdev became unwritable, and it checks every 100 ms, so it fails
#	   the pool within 300 ms of that, and so of the hold's start, if the
#	   allocation has failed by then (on a failed pool, an allocation gets
#	   a fake DVA, and nothing is held).  The block must then be written
#	   with a (fake) DVA, not completed as a hole.  If the pool didn't fail
#	   while the block was held, try again: in about a third of the tries,
#	   MMP's thread doesn't wake from its sleep until the spinning CPU lets
#	   go.
#	5. The pool exports, imports and scrubs clean.
#

verify_runnable "global"

# The held block keeps a CPU spinning, so MMP has to run on another one.
(($(psrinfo | wc -l) >= 2)) || log_unsupported "this test needs two CPUs"

typeset DSCRIPT=$TEST_BASE_DIR/enospc_reexecute.d
typeset DOUT=$TEST_BASE_DIR/enospc_reexecute.out
typeset FS=/$TESTPOOL/$TESTFS
typeset dpid="" spid=""
typeset reexecute_max=$(get_tunable zio_reexecute_max)
typeset txg_timeout=$(get_tunable zfs_txg_timeout)
typeset mmp_interval=$(get_tunable zfs_multihost_interval)
typeset mmp_fail=$(get_tunable zfs_multihost_fail_intervals)

function restore_tunables
{
	set_tunable32 zio_reexecute_max $reexecute_max >/dev/null
	set_tunable32 zfs_txg_timeout $txg_timeout >/dev/null
	set_tunable64 zfs_multihost_interval $mmp_interval >/dev/null
	set_tunable32 zfs_multihost_fail_intervals $mmp_fail >/dev/null
}

function cleanup
{
	[[ -n $dpid ]] && kill $dpid >/dev/null 2>&1
	[[ -n $spid ]] && failmode_reap $spid
	restore_tunables
	failmode_cleanup
	rm -f $DSCRIPT $DOUT
}

#
# Hold the first block of file data whose allocation fails, then say whether
# the pool had failed when the block went on to complete, and how the block
# was finally written.
#
function mkd
{
	cat > $DSCRIPT <<EOF
#pragma D option quiet
#pragma D option destructive
#pragma D option switchrate=100hz
inline string pool = "$TESTPOOL";
int fired;
BEGIN
{
	printf("ready\\n");
}
fbt::zio_ready:entry
/!fired && args[0]->io_error == ENOSPC &&
    args[0]->io_child_type == 3 /* ZIO_CHILD_LOGICAL */ &&
    args[0]->io_prop.zp_type == 19 /* DMU_OT_PLAIN_FILE_CONTENTS */ &&
    args[0]->io_prop.zp_level == 0 &&
    stringof(args[0]->io_spa->spa_name) == pool/
{
	fired = 1;
	held[arg0] = 1;
	printf("held block %d\\n", args[0]->io_bookmark.zb_blkid);
	/* chill() allows at most 500 ms per CPU per second. */
	chill(480000000);
}
fbt::zio_done:entry
/held[arg0] == 1/
{
	held[arg0] = 2;
	printf("done on a %s pool\\n",
	    args[0]->io_spa->spa_exit == 2 ? "failed" : "healthy");
}
fbt::arc_write_done:entry
/held[arg0] != 0/
{
	held[arg0] = 0;
	printf("written %s\\n",
	    args[0]->io_bp->blk_dva[0].dva_word[0] == 0 ?
	    "as a hole" : "with a DVA");
}
EOF
}

#
# The address of vdev_cant_write in the pool's only vdev, which is both its
# top-level vdev and its leaf.
#
function cant_write_addr
{
	typeset spa=$(echo "::spa" | mdb -k |
	    nawk -v pool=$TESTPOOL '$NF == pool { print $1 }')
	[[ -n $spa ]] || log_fail "can't find spa_t for $TESTPOOL"
	typeset vd=$(echo "$spa::spa -v" | mdb -k |
	    nawk '$NF ~ /^\// { print $1 }')
	[[ -n $vd ]] || log_fail "can't find the vdev_t of $TESTPOOL"
	echo "$vd::print -a vdev_t vdev_cant_write" | mdb -k |
	    nawk '{ print $1 }'
}

#
# Returns 0 if the pool failed while the block was held, after checking how
# the block was written, and 1 if it didn't.  Either way, the pool has failed
# and been exported.
#
function try_hold
{
	typeset -i t

	log_must mkfile $MINVDEVSIZE $FAILMODE_VDEV
	log_must zpool create -f -o failmode=death -o multihost=on \
	    $TESTPOOL $FAILMODE_VDEV
	log_must zfs create -o recordsize=128k -o compression=off \
	    $TESTPOOL/$TESTFS
	typeset cw=$(cant_write_addr)
	[[ -n $cw ]] || log_fail "can't find vdev_cant_write"

	dtrace -s $DSCRIPT > $DOUT 2>&1 &
	dpid=$!
	t=40
	until grep -q "^ready" $DOUT 2>/dev/null; do
		if ! kill -0 $dpid 2>/dev/null; then
			cat $DOUT
			log_fail "dtrace failed"
		fi
		((t-- == 0)) && log_fail "dtrace didn't start"
		sleep 0.5
	done

	# zfs_txg_timeout is long, so this stays dirty until the sync below.
	log_must dd if=/dev/urandom of=$FS/data bs=128k count=8
	echo "$cw/W 1" | mdb -kw >/dev/null ||
	    log_fail "can't set vdev_cant_write"
	zpool sync $TESTPOOL >/dev/null 2>&1 &
	spid=$!

	failmode_wait_failed $TESTPOOL
	# DTrace reports the hold once it ends; the block is written soon after.
	sleep 5
	if grep -q "^held" $DOUT; then
		t=30
		until grep -q "^written" $DOUT; do
			((t-- == 0)) && log_fail "the held block wasn't written"
			sleep 1
		done
	fi
	kill $dpid >/dev/null 2>&1
	dpid=""
	cat $DOUT
	failmode_reap $spid
	spid=""

	run_within 60 "zpool export of the failed pool" zpool export $TESTPOOL
	log_must test $within_rc -eq 0
	log_mustnot poolexists $TESTPOOL

	grep -q "^done on a failed pool" $DOUT || return 1
	if grep -q "^written as a hole" $DOUT; then
		log_fail "a write that failed to allocate as the pool failed" \
		    "was left as a hole"
	fi
	log_must grep -q "^written with a DVA" $DOUT
	return 0
}

log_assert "A write that fails to allocate as its pool fails isn't left as" \
    "a hole"
log_onexit cleanup

log_must set_tunable32 zio_reexecute_max 0
log_must set_tunable32 zfs_txg_timeout 60
# Before the pool is created, so that its MMP thread starts with them.  The
# healthy pool has the same short window, as the pools of
# forced_export_pinned.kshlib's pin_mmp_fast() do.
log_must set_tunable64 zfs_multihost_interval 100
log_must set_tunable32 zfs_multihost_fail_intervals 2
mkd

typeset -i try landed=0
for ((try = 1; try <= 10; try++)); do
	log_note "try $try"
	if try_hold; then
		landed=1
		break
	fi
	if grep -q "^held" $DOUT; then
		log_note "the pool didn't fail while the block was held"
	else
		log_note "the pool failed before a block failed to allocate"
	fi
	rm -f $FAILMODE_VDEV
done
((landed)) || log_fail "the pool never failed while a block that failed" \
    "to allocate was held"

# The imported pool is still failmode=death and multihost=on: give its MMP
# thread the usual fail window, so that a slow MMP write can't fail it.
restore_tunables
log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
log_must zpool scrub -w $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

log_pass "A write that fails to allocate as its pool fails isn't left as" \
    "a hole"
