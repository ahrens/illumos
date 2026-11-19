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
#	The removal of a log device from a failmode=death pool that fails
#	after the removal last checked for it, but before the txg that
#	destroys the device's metadata has synced, fails with EIO and leaves
#	the device in the pool, as it still is on disk.  Removing it again
#	fails the same way.  The pool exports, imports with the device, and
#	the device can then be removed.
#
# STRATEGY:
#	1. Create a failmode=death pool with a log device, and slow the I/O
#	   to its other vdev (one lane), so that each txg takes a while to
#	   sync.
#	2. Remove the log device.  When the removal frees the device's
#	   metaslabs, after its last check for a failed pool, DTrace fails
#	   the pool through the force-exit ioctl ("zpool export -F" without
#	   the export); zinject can't, as it waits for spa_namespace_lock,
#	   which the removal holds.
#	3. Check (with DTrace) that the txg sync dropped the device rather
#	   than syncing its removal; otherwise, try again.
#	4. Check that the removal failed with EIO, that the device is still
#	   in the pool, and that a second removal fails too.
#	5. Export the pool, import it, check that the device is there, and
#	   remove it.
#

verify_runnable "global"

typeset FEXIT=$PIN_DIR/fexit.py
typeset -i remove_rc
# One lane, so that the writes of the removal's txg queue behind each other.
PIN_LANES=1

function cleanup
{
	pin_cleanup
}

#
# Fail the pool as the removal of one of its log devices frees the device's
# metaslabs, and say whether the txg sync then dropped the device or synced
# it, and what spa_vdev_remove() returned.
#
function mkd
{
	cat > $PIN_D <<EOF
#pragma D option quiet
#pragma D option destructive
#pragma D option switchrate=100hz
inline string pool = "$TESTPOOL";
int fired;
uint64_t logvd;
BEGIN
{
	printf("ready\\n");
}
fbt::vdev_metaslab_fini:entry
/!fired && args[0]->vdev_islog && args[0]->vdev_removing &&
    stringof(args[0]->vdev_spa->spa_name) == pool/
{
	fired = 1;
	logvd = (uint64_t)args[0];
	system("python $FEXIT $TESTPOOL");
	printf("fired\\n");
}
fbt::zfs_ioc_pool_force_exit:return
/fired/
{
	printf("pool failed, rc %d\\n", arg1);
}
fbt::vdev_sync_discard:entry
/fired && (uint64_t)args[0] == logvd/
{
	printf("discarded in txg %d\\n", args[1]);
}
fbt::vdev_sync:entry
/fired && (uint64_t)args[0] == logvd/
{
	printf("synced in txg %d\\n", args[1]);
}
fbt::spa_vdev_remove:return
/fired/
{
	printf("spa_vdev_remove returned %d\\n", arg1);
}
EOF
}

#
# Create the pool and remove its log device while DTrace fails the pool.
# Returns 0 if the pool failed before the removal's txg synced the device.
#
function try_remove
{
	rm -rf $PIN_VD
	log_must mkdir -p $PIN_VD
	log_must mkfile 256m $PIN_V1 $PIN_SLOG
	log_must zpool create -f -o failmode=death $TESTPOOL $PIN_V1 \
	    log $PIN_SLOG
	log_must zpool sync $TESTPOOL

	mkd
	pin_start_d
	pin_slow 500 $PIN_V1
	zpool remove $TESTPOOL $PIN_SLOG
	remove_rc=$?
	log_note "zpool remove returned $remove_rc"

	typeset -i t=60
	until grep -q "^spa_vdev_remove returned" $PIN_OUT; do
		((t-- == 0)) && break
		sleep 1
	done
	kill $pin_dpid >/dev/null 2>&1
	failmode_reap $pin_dpid
	pin_dpid=""
	cat $PIN_OUT

	grep -q "^fired" $PIN_OUT || log_fail "the removal never fired"
	failmode_wait_failed $TESTPOOL
	if grep -q "^discarded" $PIN_OUT && ! grep -q "^synced" $PIN_OUT; then
		return 0
	fi

	log_note "the removal's txg synced the device before the pool failed"
	pin_export_failed
	return 1
}

log_assert "A log device removal on a pool that fails before it syncs" \
    "fails, and leaves the device in the pool"
log_onexit cleanup

log_must mkdir -p $PIN_DIR
cat > $FEXIT <<'EOF'
# fexit.py <pool>: fail the pool, as "zpool export -F" does before it
# exports it.
import ctypes, sys
z = ctypes.CDLL("libzfs.so.1")
z.libzfs_init.restype = ctypes.c_void_p
h = ctypes.c_void_p(z.libzfs_init())
sys.exit(z.zpool_force_exit_name(h, sys.argv[1].encode(), 0))
EOF

typeset -i try
for ((try = 1; try <= 3; try++)); do
	log_note "try $try"
	try_remove && break
done
((try > 3)) && log_fail "the pool never failed before the removal synced"

log_must grep -q "^pool failed, rc 0" $PIN_OUT
((remove_rc != 0)) || log_fail "zpool remove succeeded on a failed pool"
# EIO
log_must grep -q '^spa_vdev_remove returned 5$' $PIN_OUT
log_must vdevs_in_pool $TESTPOOL $PIN_SLOG
log_mustnot zpool remove $TESTPOOL $PIN_SLOG
log_must vdevs_in_pool $TESTPOOL $PIN_SLOG

pin_export_failed
log_must zpool import -d $PIN_VD $TESTPOOL
log_must vdevs_in_pool $TESTPOOL $PIN_SLOG
log_must zpool remove $TESTPOOL $PIN_SLOG
log_mustnot vdevs_in_pool $TESTPOOL $PIN_SLOG
log_must zpool scrub -w $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"
log_must zpool destroy $TESTPOOL

log_pass "A log device removal on a pool that fails before it syncs" \
    "fails, and leaves the device in the pool"
