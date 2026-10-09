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
#	"zpool export -F" of a suspended pool fails it and exports it, and
#	none of the I/O that was parked while it was suspended reaches its
#	disk, even though the disk works again by then.  The threads that
#	were waiting on the pool return, and the pool can be imported again
#	as of the last txg that synced before it suspended, with no leaked
#	space or bad checksums (zdb -bcc).  The same holds for a pool with
#	two disks of which only one fails: the other one, which keeps working,
#	gets no writes either.
#

typeset FAILMODE_VDEV2=$TEST_BASE_DIR/failmode_vdev2
typeset -a pids

function cleanup
{
	zinject -c all >/dev/null 2>&1
	pool_is_suspended $TESTPOOL && zpool clear $TESTPOOL
	for pid in ${pids[@]}; do
		kill $pid >/dev/null 2>&1
		wait $pid
	done
	failmode_cleanup
	rm -f $FAILMODE_VDEV2
}

#
# Suspend a pool on the given disks (only the first one fails), export it
# with -F, and check what's on the disks.
#
function fence_case # vdev...
{
	typeset vdev d1 d2

	log_note "fence case: $*"
	for vdev in "$@"; do
		log_must mkfile $MINVDEVSIZE $vdev
	done
	log_must zpool create -f -o failmode=wait $TESTPOOL "$@"
	log_must zfs create -o recordsize=128k $TESTPOOL/$TESTFS
	log_must zfs create $TESTPOOL/$TESTFS/child
	log_must zfs set user:before=1 $TESTPOOL
	sync_pool $TESTPOOL

	#
	# Dirty the pool with writes, and with administrative commands that
	# wait for it.  The file systems stay mounted: "zpool export -F" arms
	# the pool before it unmounts them, so that unmounting doesn't wait for
	# the pool forever.
	#
	failmode_break_vdev
	log_must dd if=/dev/urandom of=/$TESTPOOL/$TESTFS/dirty bs=128k count=8
	zfs set user:dirty=1 $TESTPOOL &
	pids+=($!)
	zfs create $TESTPOOL/new &
	pids+=($!)
	zfs snapshot -r $TESTPOOL@snap &
	pids+=($!)

	typeset -i tries=30
	until pool_is_suspended $TESTPOOL; do
		if ((tries-- == 0)); then
			log_fail "pool didn't suspend"
		fi
		sleep 1
	done

	#
	# Make the disk work again, without resuming the pool.  The injection
	# handlers also hold the pool, which would keep it from being
	# exported.
	#
	log_must zinject -c all
	sleep 2
	d1=$(for vdev in "$@"; do vdev_digest $vdev; done)

	run_within 60 "zpool export -F of the suspended pool" \
	    zpool export -F $TESTPOOL
	log_must test $within_rc -eq 0
	log_mustnot poolexists $TESTPOOL

	d2=$(for vdev in "$@"; do vdev_digest $vdev; done)
	[[ $d1 == $d2 ]] || log_fail "the failed pool wrote to its disks"

	# Everything that was waiting on the pool has returned.
	for pid in ${pids[@]}; do
		typeset -i tries=30
		while kill -0 $pid 2>/dev/null; do
			if ((tries-- == 0)); then
				log_fail "pid $pid is still waiting for the pool"
			fi
			sleep 1
		done
		wait $pid
		log_note "pid $pid returned $?"
	done
	set -A pids

	# The disk holds the pool as of the last txg that synced.
	log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
	log_must test "$(get_prop user:before $TESTPOOL)" == "1"
	log_must test "$(get_prop user:dirty $TESTPOOL)" == "-"
	log_mustnot datasetexists $TESTPOOL/new
	log_mustnot test -e /$TESTPOOL/$TESTFS/dirty
	log_mustnot datasetexists $TESTPOOL@snap
	log_must datasetexists $TESTPOOL/$TESTFS/child
	log_must zpool scrub $TESTPOOL
	log_must wait_scrubbed $TESTPOOL
	log_must check_pool_status $TESTPOOL "errors" "No known data errors"

	# Nothing leaked, and every block checksums.
	log_must zpool export $TESTPOOL
	log_must zdb -e -p $TEST_BASE_DIR -bcc $TESTPOOL
	rm -f "$@"
}

log_assert "zpool export -F of a suspended pool writes nothing to its disk"
log_onexit cleanup

fence_case $FAILMODE_VDEV
fence_case $FAILMODE_VDEV $FAILMODE_VDEV2

log_pass "zpool export -F of a suspended pool writes nothing to its disk"
