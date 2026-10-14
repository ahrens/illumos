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
#	A failmode=death pool fails cleanly at each phase of a txg sync:
#	while it writes the datasets, while it writes the MOS, in a later
#	sync pass, while it writes the labels, and in a txg that frees
#	blocks, syncs metaslabs or flushes the log space maps.  Each time,
#	the pool exports, imports with every write whose fsync() returned
#	0, and scrubs clean.  (With log space maps, which new pools have,
#	frees are not deferred, so there is no deferred-free phase.)
#
# STRATEGY:
#	For each phase, with fsync() writers running and the pool's I/O
#	slowed, make every write fail as the sync thread enters the phase
#	(see forced_export_pinned.kshlib).  The phases that write fail inside
#	the function; for those that only change state in memory (frees,
#	metaslab_sync, the log space map flush) or whose failure the sync
#	thread acts on after they return (labels), the pool fails before
#	that txg's spa_sync() returns.
#

typeset PRED_DP='stringof(args[0]->dp_spa->spa_name) == pool'
typeset PRED_SPA='stringof(args[0]->spa_name) == pool'
typeset SYNC_END='fbt::spa_sync:return curthread'

function cleanup
{
	pin_cleanup
}

# Fsync()ing writers and a big write, with the pool's I/O slowed.
function busy_pool
{
	pin_mkpool
	pin_writer w0 fsync
	pin_bg dd if=/dev/urandom of=$PIN_FS/big bs=1024k count=200
	sleep 3
	pin_slow 500 $PIN_V1 $PIN_V2
	FAULT=$(pin_fault_cmd $PIN_V1 $PIN_V2)
}

# A big file of small blocks, to free.
function big_file_pool
{
	pin_mkpool
	log_must zfs set recordsize=4k $TESTPOOL/$TESTFS
	log_must dd if=/dev/urandom of=$PIN_FS/big bs=1024k count=300
	log_must zpool sync $TESTPOOL
	pin_writer w0 fsync
	sleep 3
	pin_slow 500 $PIN_V1 $PIN_V2
	FAULT=$(pin_fault_cmd $PIN_V1 $PIN_V2)
}

function datasets
{
	busy_pool
	pin_d_entry fbt::dsl_pool_sync:entry \
	    "$PRED_DP && args[0]->dp_spa->spa_sync_pass == 1" curthread \
	    fbt::dsl_pool_sync:return curthread
}

function mos
{
	busy_pool
	pin_d_entry fbt::dsl_pool_sync_mos:entry "$PRED_DP" curthread \
	    fbt::dsl_pool_sync_mos:return curthread
}

function later_pass
{
	busy_pool
	pin_d_entry fbt::dsl_pool_sync:entry \
	    "$PRED_DP && args[0]->dp_spa->spa_sync_pass >= 2" curthread \
	    fbt::dsl_pool_sync:return curthread
}

function frees
{
	big_file_pool
	# dsl_free() runs in the sync taskq, not on the sync thread.
	pin_d_entry fbt::dsl_free:entry "$PRED_DP" \
	    "args[0]->dp_tx.tx_sync_thread" $SYNC_END
}
function frees_go
{
	log_must rm $PIN_FS/big
}

function metaslabs
{
	busy_pool
	pin_d_entry fbt::metaslab_sync:entry \
	    "stringof(args[0]->ms_group->mg_vd->vdev_spa->spa_name) == pool" \
	    curthread $SYNC_END
}

function log_spacemaps
{
	busy_pool
	pin_d_entry fbt::spa_flush_metaslabs:entry "$PRED_SPA" curthread \
	    $SYNC_END
}

# The label writes fail; the pool fails in spa_sync() right after them.
function labels
{
	pin_mkpool
	pin_writer w0 fsync
	sleep 3
	pin_slow 500 $PIN_V1 $PIN_V2
	FAULT=$(pin_fault_cmd $PIN_V1 $PIN_V2)
	pin_d_entry fbt::vdev_config_sync:entry \
	    "stringof(args[0][0]->vdev_spa->spa_name) == pool" curthread \
	    $SYNC_END
}

log_assert "A failmode=death pool fails cleanly at each phase of a txg sync"
log_onexit cleanup

pin_mkwriter
for c in datasets mos later_pass frees metaslabs log_spacemaps labels; do
	pin_run $c 5
done

log_pass "A failmode=death pool fails cleanly at each phase of a txg sync"
