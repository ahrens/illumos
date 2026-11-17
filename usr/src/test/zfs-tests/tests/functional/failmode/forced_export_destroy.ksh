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
#	A destroy of a clone that is running in syncing context when its
#	pool fails gets past the blocks it can no longer read, and fails.
#	The disks keep the last committed txg, so the clone is still there
#	after an export and import.
#
# STRATEGY:
#	1. Create a failmode=death pool with a file system, a snapshot of
#	   it, and a clone of the snapshot that is never mounted.  Disable
#	   embedded_data, so that small blocks such as the origin's list of
#	   clones are stored in blocks of their own.
#	2. Empty the caches: export the pool and import it without mounting
#	   anything, with the dbuf caches turned off, and flush the ARC.
#	   Turn the dbuf caches back on, and read the clone, but not the
#	   origin's list of clones.
#	3. Delay every I/O to the vdev by 3 seconds, and destroy the clone.
#	   When the destroy starts in syncing context, DTrace fails the pool
#	   through the force-exit ioctl ("zpool export -F" without the
#	   export).  The destroy's first read that misses the cache was
#	   issued before that, and completes late; the reads after it come
#	   back as errors, or as zeros (poisoned).
#	4. Check that "zfs destroy" failed, that the pool failed while the
#	   destroy ran, and that the destroy read poisoned blocks.
#	5. Export the pool, import it, and check that the clone is there.
#

verify_runnable "global"

typeset DIR=$TEST_BASE_DIR/forced_export_destroy
typeset D=$DIR/destroy.d
typeset DOUT=$DIR/destroy.d.out
typeset DERR=$DIR/destroy.d.err
typeset FEXIT=$DIR/fexit.py
typeset CLONE=$TESTPOOL/clone
typeset md_max=$(get_tunable dbuf_metadata_cache_max_bytes)
typeset dbuf_max=$(get_tunable dbuf_cache_max_bytes)
typeset dpid=""

function restore_caches
{
	set_tunable64 dbuf_metadata_cache_max_bytes $md_max >/dev/null
	set_tunable64 dbuf_cache_max_bytes $dbuf_max >/dev/null
}

function cleanup
{
	[[ -n $dpid ]] && kill $dpid >/dev/null 2>&1
	failmode_reap $dpid
	restore_caches
	failmode_cleanup
	rm -rf $DIR
}

log_assert "A destroy that its pool fails under doesn't panic"
log_onexit cleanup

log_must mkdir -p $DIR
log_must mkfile $MINVDEVSIZE $FAILMODE_VDEV
log_must zpool create -f -o failmode=death \
    -o feature@embedded_data=disabled $TESTPOOL $FAILMODE_VDEV
log_must zfs create -o compression=off $TESTPOOL/$TESTFS
log_must dd if=/dev/urandom of=/$TESTPOOL/$TESTFS/file bs=128k count=16
log_must zfs snapshot $TESTPOOL/$TESTFS@snap
log_must zfs clone -o canmount=off $TESTPOOL/$TESTFS@snap $CLONE
log_must dd if=/dev/urandom of=/$TESTPOOL/$TESTFS/file2 bs=128k count=16

log_must zpool export $TESTPOOL
log_must set_tunable64 dbuf_metadata_cache_max_bytes 0
log_must set_tunable64 dbuf_cache_max_bytes 0
log_must zpool import -N -d $(dirname $FAILMODE_VDEV) $TESTPOOL
log_must zinject -a
restore_caches
log_must zfs list $CLONE

cat > $FEXIT <<'EOF'
# fexit.py <pool>: fail the pool, as "zpool export -F" does before it
# exports it.
import ctypes, sys
z = ctypes.CDLL("libzfs.so.1")
z.libzfs_init.restype = ctypes.c_void_p
h = ctypes.c_void_p(z.libzfs_init())
sys.exit(z.zpool_force_exit_name(h, sys.argv[1].encode(), 0))
EOF

#
# $1: the pool, $2: fexit.py.  "poisoned" lines are reads by the destroy
# that came back as zeros because the pool had failed.
#
cat > $D <<'EOF'
#pragma D option quiet
#pragma D option destructive
#pragma D option switchrate=100hz

BEGIN
{
	printf("ready\n");
}

fbt::dsl_destroy_head_sync_impl:entry
/!started/
{
	started = 1;
	printf("destroy starts\n");
	system("python %s %s", $$2, $$1);
}

fbt::zfs_ioc_pool_force_exit:return
{
	printf("pool failed, rc %d\n", arg1);
}

sdt:::spa-exit-poisoned-read
/started/
{
	printf("poisoned %d %d %d\n", ((zbookmark_phys_t *)arg1)->zb_object,
	    ((zbookmark_phys_t *)arg1)->zb_level,
	    ((zbookmark_phys_t *)arg1)->zb_blkid);
}

fbt::dsl_destroy_head_sync_impl:return
/started/
{
	printf("destroy returns\n");
}
EOF
dtrace -s $D $TESTPOOL $FEXIT >$DOUT 2>$DERR &
dpid=$!
typeset -i t=120
until grep -q ready $DOUT 2>/dev/null; do
	kill -0 $dpid 2>/dev/null || log_fail "dtrace failed: $(<$DERR)"
	((t-- == 0)) && log_fail "dtrace didn't start"
	sleep 0.5
done

log_must zinject -d $FAILMODE_VDEV -D 3000:1 $TESTPOOL
zfs destroy $CLONE
typeset -i drc=$?
log_note "zfs destroy $CLONE returned $drc"
sleep 1
kill $dpid
failmode_reap $dpid
dpid=""
log_note "DTrace: $(<$DOUT)"

grep -q "destroy returns" $DOUT || log_fail "the destroy didn't run"
grep -q "pool failed, rc 0" $DOUT ||
    log_fail "the pool didn't fail during the destroy"
pool_has_failed $TESTPOOL || log_fail "$TESTPOOL hasn't failed"
grep -q "^poisoned" $DOUT ||
    log_fail "the destroy didn't read anything from the failed pool"
((drc != 0)) || log_fail "zfs destroy succeeded on a failed pool"

log_must zinject -c all
log_must zpool export -f $TESTPOOL
log_must zpool import -d $(dirname $FAILMODE_VDEV) $TESTPOOL
log_must datasetexists $CLONE
log_must zfs destroy $CLONE

log_pass "A destroy that its pool fails under doesn't panic"
