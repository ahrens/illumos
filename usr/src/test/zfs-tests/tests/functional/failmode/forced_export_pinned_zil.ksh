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
#	A failmode=death pool fails cleanly at each point of a ZIL commit and
#	of ZIL replay: with a thread in zil_commit(), with a log block
#	written but not yet done, with a log block written and its cache
#	flush not yet done, with an indirect write (dmu_sync()) in flight,
#	and during replay at mount.  Every write whose fsync() or O_DSYNC
#	write returned 0 before the failure is there after re-import.
#
# STRATEGY:
#	See forced_export_pinned.kshlib.  To keep a log block or an indirect
#	write in flight while the pool fails, only the device it goes to is
#	slow, and something else fails the pool: the next txg sync's own
#	writes (log block), or MMP (indirect write, cache flush), since those
#	writes don't fail the pool themselves.  For replay, the records are
#	written after "zpool freeze", so that they are only in the log.
#

typeset PRED_ZL='stringof(args[0]->zl_spa->spa_name) == pool'

function cleanup
{
	pin_cleanup
}

function commit
{
	pin_mkpool
	pin_writer w0 fsync
	pin_writer w1 fsync
	sleep 3
	pin_slow 500 $PIN_V1 $PIN_V2
	FAULT=$(pin_fault_cmd $PIN_V1 $PIN_V2)
	pin_d_entry fbt::zil_commit:entry "$PRED_ZL" curthread \
	    fbt::zil_commit:return curthread
}

function lwb_in_flight
{
	pin_mkslog
	pin_mkpool log $PIN_SLOG
	pin_writer w0 fsync
	pin_writer w1 dsync
	sleep 3
	pin_slow 5000 $PIN_SLOG
	FAULT=$(pin_fault_cmd $PIN_V1 $PIN_V2 $PIN_SLOG)
	pin_d_inflight fbt::zil_lwb_write_issue:entry "$PRED_ZL" "args[1]" \
	    fbt::zil_lwb_write_done:entry "args[0]->io_private"
}

#
# The slog is a file in another pool whose I/O is slow, so that its cache
# flush (an fsync() of that file) takes a while.
#
function lwb_flush
{
	rm -rf $PIN_SLOW
	log_must mkdir -p $PIN_VD $PIN_SLOW
	log_must mkfile 1g $PIN_SLOW/vdev
	log_must zpool create -f $PIN_POOL2 $PIN_SLOW/vdev
	log_must mkfile 256m /$PIN_POOL2/slog
	pin_import_dirs="-d $PIN_VD -d /$PIN_POOL2"
	pin_mkpool log /$PIN_POOL2/slog
	pin_mmp_fast
	pin_writer w0 fsync
	sleep 3
	log_must eval "zinject -d $PIN_SLOW/vdev -D 1000:64 $PIN_POOL2 \
	    >/dev/null"
	FAULT=$(pin_fault_cmd $PIN_V1 $PIN_V2 /$PIN_POOL2/slog)
	pin_d_entry fbt::zio_flush:entry \
	    "(uintptr_t)args[0]->io_done == (uintptr_t)&\`zil_lwb_flush_vdevs_done && stringof(args[0]->io_spa->spa_name) == pool" \
	    "args[0]->io_private" \
	    fbt::zil_lwb_flush_vdevs_done:entry "args[0]->io_private"
}

#
# Only v1 is slow, so MMP keeps succeeding on v2 until the failure; an
# indirect write that lands on v1 is still in flight when MMP fails the pool.
#
function indirect
{
	pin_mkpool
	pin_mmp_fast
	log_must zfs set logbias=throughput $TESTPOOL/$TESTFS
	pin_writer w0 fsync
	pin_writer w1 dsync
	sleep 3
	pin_slow 2000 $PIN_V1
	FAULT=$(pin_fault_cmd $PIN_V1 $PIN_V2)
	pin_d_entry fbt::dmu_sync:entry \
	    "stringof(args[3]->zgd_lwb->lwb_zilog->zl_spa->spa_name) == pool" \
	    "args[3]" \
	    fbt::dmu_sync_done:entry "((dmu_sync_arg_t *)args[2])->dsa_zgd"
}

function replay
{
	pin_mkslog
	pin_mkpool log $PIN_SLOG
	# A sync write first, so that the log is on disk before the freeze.
	log_must python -c "import os; fd = os.open('$PIN_FS/first', \
	    os.O_WRONLY | os.O_CREAT | os.O_DSYNC); os.write(fd, b'x')"
	log_must zpool sync $TESTPOOL
	log_must zpool freeze $TESTPOOL
	pin_writer w0 fsync
	pin_writer w1 dsync
	sleep 5
	pin_kill_bg
	log_must zpool export $TESTPOOL
	log_must zpool import -N -d $PIN_VD $TESTPOOL
	log_must zfs mount $TESTPOOL
	pin_slow 500 $PIN_V1 $PIN_V2 $PIN_SLOG
	FAULT=$(pin_fault_cmd $PIN_V1 $PIN_V2 $PIN_SLOG)
	pin_d_entry fbt::zil_replay:entry \
	    "stringof(args[0]->os_spa->spa_name) == pool" curthread \
	    fbt::zil_replay:return curthread
}
function replay_go
{
	pin_bg zfs mount $TESTPOOL/$TESTFS
}

log_assert "A failmode=death pool fails cleanly at each point of a ZIL" \
    "commit and of ZIL replay"
log_onexit cleanup

pin_mkwriter
pin_run commit 5
pin_run lwb_in_flight 5
pin_run lwb_flush 5
# The indirect write lands on the slow vdev about half of the time.
pin_run indirect 10
pin_run replay 5

log_pass "A failmode=death pool fails cleanly at each point of a ZIL" \
    "commit and of ZIL replay"
