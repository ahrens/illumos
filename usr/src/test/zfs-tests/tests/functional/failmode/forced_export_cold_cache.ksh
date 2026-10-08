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
#	A pool that fails with nothing cached, while it syncs changes that
#	free, truncate and overwrite large files, drains and is exported
#	without panicking or hanging: the blocks its syncing context can't
#	read are poisoned (counted by zfs:0:forced_exit:poisoned_reads), and
#	the disk keeps the last committed txg.  This holds for a
#	failmode=death pool, which fails by itself, and for a failmode=wait
#	pool that suspends and is failed by "zpool export -F".
#
# STRATEGY:
#	1. Write large files with small records, so they have many indirect
#	   blocks, then export and import the pool to empty the caches.
#	2. Stop txgs from syncing by themselves, and change the files: remove
#	   one, truncate one and overwrite blocks all over the third.
#	3. Flush the ARC, make writes fail, and sync the pool.
#	4. Export the pool, import it, check the files and scrub it.
#

typeset FS=/$TESTPOOL/$TESTFS
typeset -i txg_timeout=$(get_tunable zfs_txg_timeout)
typeset -i sync_pid=0

function poisoned_reads
{
	kstat forced_exit.poisoned_reads
}

function cleanup
{
	set_tunable32 zfs_txg_timeout $txg_timeout
	zinject -c all >/dev/null 2>&1
	pool_is_suspended $TESTPOOL && zpool clear $TESTPOOL
	if ((sync_pid != 0)); then
		kill $sync_pid >/dev/null 2>&1
		wait $sync_pid
	fi
	failmode_cleanup
}

log_assert "A pool that fails with nothing cached drains and is exported"
log_onexit cleanup

for mode in death wait; do
	log_note "failmode=$mode"
	failmode_create_pool $mode
	# sync=disabled keeps the ZIL, which has nothing to do with this, out.
	log_must zfs set recordsize=4k compression=off sync=disabled \
	    $TESTPOOL/$TESTFS
	for f in removed truncated overwritten; do
		log_must dd if=/dev/urandom of=$FS/$f bs=1024k count=16
	done
	typeset sum=$(digest -a sha256 $FS/truncated)
	log_must zpool export $TESTPOOL
	log_must zpool import -d $TEST_BASE_DIR $TESTPOOL

	log_must set_tunable32 zfs_txg_timeout 3600
	log_must rm $FS/removed
	log_must eval ": > $FS/truncated"
	for ((i = 0; i < 4096; i += 97)); do
		log_must dd if=/dev/urandom of=$FS/overwritten bs=4k count=1 \
		    seek=$i conv=notrunc
	done

	typeset -i before=$(poisoned_reads)
	log_must zinject -a -d $FAILMODE_VDEV -e io -T write $TESTPOOL
	log_must zinject -d $FAILMODE_VDEV -L pad2 $TESTPOOL
	zpool sync $TESTPOOL &
	sync_pid=$!

	if [[ $mode == death ]]; then
		failmode_wait_failed $TESTPOOL
		log_must zinject -c all
		run_within 60 "zpool export of the failed pool" \
		    zpool export $TESTPOOL
	else
		typeset -i tries=30
		until pool_is_suspended $TESTPOOL; do
			if ((tries-- == 0)); then
				log_fail "pool didn't suspend"
			fi
			sleep 1
		done
		log_must zinject -c all
		run_within 60 "zpool export -F of the suspended pool" \
		    zpool export -F $TESTPOOL
	fi
	log_must test $within_rc -eq 0
	log_mustnot poolexists $TESTPOOL
	wait $sync_pid
	sync_pid=0

	typeset -i after=$(poisoned_reads)
	log_note "$((after - before)) blocks were poisoned"

	log_must set_tunable32 zfs_txg_timeout $txg_timeout
	log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
	log_must test -f $FS/removed
	log_must test "$(digest -a sha256 $FS/truncated)" == "$sum"
	log_must zpool scrub $TESTPOOL
	log_must wait_scrubbed $TESTPOOL
	log_must check_pool_status $TESTPOOL "errors" "No known data errors"
	failmode_cleanup
done

log_pass "A pool that fails with nothing cached drains and is exported"
