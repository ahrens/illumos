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
#	A file system can be torn down while zfs_inactive() writes out the
#	dirty pages of a file whose last mapping has just gone away: a forced
#	unmount on a healthy pool keeps the pages, and "zpool export -F" of a
#	failmode=death pool succeeds.
#
# STRATEGY:
#	The file is mapped shared and closed, and its pages are dirtied, so
#	that unmapping it drops its last hold and zfs_inactive() writes the
#	pages out.  The file system is mounted again after the file is
#	written, and normalizes names, so that no name cache entry holds the
#	file; fsflush is turned off, so that the pages stay dirty.  Once the
#	pool has synced, its I/O is slowed with "zinject -D", and DTrace says
#	when to unmap the file, and whether the timing worked out.  Each case
#	is tried up to 3 times until it does.
#	1. unmount: a healthy pool, whose txgs sync only when waited for.
#	   Write another file, so that the zil_close() of "zfs unmount -f"
#	   waits for a txg that has writes to make.  Unmap the file while
#	   that txg is syncing, so that the pages are written in the next
#	   txg.  The unmount succeeds, and the file has the new contents when
#	   it is mounted again.
#	2. export: a failmode=death pool with primarycache=metadata, and one
#	   dirty page in a 128k block, so that zfs_inactive() reads the block
#	   once its tx is assigned.  "zpool export -F" while that read is in
#	   flight (it fails the pool and detaches the file system) succeeds.
#

verify_runnable "global"

typeset DP_DIR=$TEST_BASE_DIR/dirty_pages
typeset DP_VDEV=$DP_DIR/vdev
typeset DP_FS=$TESTPOOL/$TESTFS
typeset DP_MNT=/$TESTPOOL/$TESTFS
typeset DP_PY=$DP_DIR/unmap.py
typeset DP_D=$DP_DIR/dirty_pages.d
typeset DP_OUT=$DP_DIR/dirty_pages.out
typeset dp_hpid="" dp_dpid="" dp_opid="" dp_saved=""
typeset -i dp_hit=0

function dp_restore
{
	if [[ -n $dp_saved ]]; then
		echo "$dp_saved" | mdb -kw >/dev/null
		dp_saved=""
	fi
}

function dp_stop
{
	[[ -n $dp_hpid ]] && touch $DP_DIR/go
	[[ -n $dp_dpid ]] && kill $dp_dpid >/dev/null 2>&1
	failmode_reap $dp_hpid $dp_dpid $dp_opid
	dp_hpid=""
	dp_dpid=""
	dp_opid=""
	zinject -c all >/dev/null 2>&1
	dp_restore
}

function dp_remove_pool
{
	if poolexists $TESTPOOL && pool_has_failed $TESTPOOL; then
		log_must zpool export -f $TESTPOOL
	elif poolexists $TESTPOOL; then
		destroy_pool $TESTPOOL
	fi
	#
	# Exporting a failed pool leaves its mountpoints behind, and the
	# pool's root isn't mounted, so they are on the root file system,
	# where "zpool create" would find /$TESTPOOL not empty.
	#
	rmdir $DP_MNT /$TESTPOOL >/dev/null 2>&1
}

function cleanup
{
	dp_stop
	dp_remove_pool
	if mount -p | nawk -v m=$DP_MNT '$3 == m { f = 1 } END { exit !f }'
	then
		umount -f $DP_MNT
	fi
	rmdir $DP_MNT /$TESTPOOL >/dev/null 2>&1
	rm -rf $DP_DIR
}

function dp_mkfiles
{
	log_must mkdir -p $DP_DIR
	cat > $DP_PY <<'EOF'
# unmap.py <file> <all|first> <dir>: map the file shared, close it, and
# dirty every page (or the first one); write what the file should then hold
# to <dir>/expect and create <dir>/dirty.  Once <dir>/go exists, unmap it,
# which drops the file's last hold.
import ctypes, os, sys, time
path, pages, d = sys.argv[1:4]
libc = ctypes.CDLL(None, use_errno=True)
libc.mmap.restype = ctypes.c_void_p
libc.mmap.argtypes = (ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
    ctypes.c_int, ctypes.c_int, ctypes.c_long)
libc.munmap.argtypes = (ctypes.c_void_p, ctypes.c_size_t)
fd = os.open(path, os.O_RDWR)
size = os.fstat(fd).st_size
# PROT_READ | PROT_WRITE, MAP_SHARED
p = libc.mmap(None, size, 3, 1, fd, 0)
if p is None or p == ctypes.c_void_p(-1).value:
	sys.exit("mmap: " + os.strerror(ctypes.get_errno()))
os.close(fd)
buf = (ctypes.c_ubyte * size).from_address(p)
pg = os.sysconf("SC_PAGESIZE")
for off in range(0, size if pages == "all" else 1, pg):
	buf[off] ^= 0xff
with open(os.path.join(d, "expect"), "wb") as f:
	f.write(ctypes.string_at(p, size))
open(os.path.join(d, "dirty"), "w").close()
while not os.path.exists(os.path.join(d, "go")):
	time.sleep(0.01)
if libc.munmap(p, size) != 0:
	sys.exit("munmap: " + os.strerror(ctypes.get_errno()))
EOF
	cat > $DP_D <<'EOF'
#pragma D option quiet
#pragma D option switchrate=100hz
/*
 * $1: pid that unmaps the file, $2: pool, $3: the file's object number.
 * "Z" lines are the teardown (zil_close() and its txg wait), "T" lines are
 * zfs_inactive()'s page write.  Each line starts with the time in
 * microseconds: lines from different CPUs can come out of order.
 */
inline string pool = $$2;
uint64_t waitfor, syncing, synced;
uintptr_t lk;

BEGIN
{
	printf("ready\n");
}

fbt::spa_sync:entry
/stringof(args[0]->spa_name) == pool/
{
	self->txg = arg1;
	syncing = arg1;
}

fbt::spa_sync:entry
/self->txg && waitfor != 0 && arg1 >= waitfor/
{
	printf("%d Z syncing %d\n", timestamp / 1000, arg1);
	waitfor = 0;
}

fbt::spa_sync:return
/self->txg/
{
	synced = self->txg;
	syncing = 0;
	self->txg = 0;
}

fbt::zil_close:entry
/stringof(args[0]->zl_spa->spa_name) == pool/
{
	self->zc = 1;
	printf("%d Z zil_close\n", timestamp / 1000);
}

fbt::zil_commit:entry
/self->zc/
{
	self->cm = 1;
}

fbt::zil_commit:return
/self->zc/
{
	self->cm = 0;
}

fbt::txg_wait_synced:entry
/self->zc && !self->cm/
{
	printf("%d Z waits for txg %d (syncing %d, synced %d)\n",
	    timestamp / 1000, arg1, syncing, synced);
	waitfor = arg1;
}

fbt::txg_wait_synced:entry
/self->zc && !self->cm && syncing != 0 && syncing >= arg1/
{
	printf("%d Z syncing %d\n", timestamp / 1000, syncing);
	waitfor = 0;
}

fbt::zil_close:return
/self->zc/
{
	printf("%d Z zil_close done\n", timestamp / 1000);
	self->zc = 0;
	self->cm = 0;
	waitfor = 0;
}

fbt::zfs_inactive:entry
/pid == $1 && ((znode_t *)args[0]->v_data)->z_id == $3/
{
	self->in = 1;
	lk = (uintptr_t)((znode_t *)args[0]->v_data)->z_zfsvfs +
	    offsetof(zfsvfs_t, z_teardown_inactive_lock);
	printf("%d T inactive\n", timestamp / 1000);
}

fbt::dmu_tx_assign:entry
/self->in/
{
	self->tx = args[0];
}

fbt::dmu_tx_assign:return
/self->tx/
{
	printf("%d T assigned %d rc %d\n", timestamp / 1000,
	    self->tx->tx_txg, arg1);
	self->tx = 0;
	self->asg = 1;
}

/*
 * The read of the file's first block once the tx is assigned (not that of
 * its dnode's block, which is cached).
 */
fbt::dbuf_read:entry
/self->asg && args[0]->db.db_object == $3 && args[0]->db_level == 0 &&
    args[0]->db_blkid == 0/
{
	self->rd = timestamp;
	printf("%d T reads\n", timestamp / 1000);
}

fbt::dbuf_read:return
/self->rd/
{
	printf("%d T read done %d ms\n", timestamp / 1000,
	    (timestamp - self->rd) / 1000000);
	self->rd = 0;
}

fbt::zfs_log_write:entry
/self->in/
{
	printf("%d T log %x\n", timestamp / 1000, arg0);
}

fbt::zfs_putapage:return
/self->in/
{
	self->asg = 0;
}

fbt::zfs_inactive:return
/self->in/
{
	printf("%d T inactive done\n", timestamp / 1000);
	self->in = 0;
	self->asg = 0;
}

fbt::rw_enter_sleep:entry
/lk != 0 && arg0 == lk && arg1 == 0/
{
	printf("%d Z waits for the inactive lock (%s)\n", timestamp / 1000,
	    execname);
}
EOF
}

#
# Wait up to $1 seconds for a line of DTrace output that matches $2; give up
# early if one that matches $3 comes first.
#
function dp_wait
{
	typeset -i t=$(($1 * 10))

	while ! grep -q "$2" $DP_OUT 2>/dev/null; do
		[[ -n $3 ]] && grep -q "$3" $DP_OUT 2>/dev/null && return 1
		((t-- == 0)) && return 1
		sleep 0.1
	done
	return 0
}

# The time of the first line of DTrace output that matches $1, or 0.
function dp_time
{
	nawk -v p="$1" '$0 ~ p { t = $1; exit }
	    END { print (t == "" ? 0 : t) }' $DP_OUT
}

#
# Wait up to $1 seconds for the background command, and return its exit
# status.
#
function dp_wait_op
{
	typeset -i t=$1

	while kill -0 $dp_opid 2>/dev/null; do
		((t-- == 0)) && log_fail "the forced unmount or export hung"
		sleep 1
	done
	wait $dp_opid
	typeset -i rc=$?
	dp_opid=""
	return $rc
}

#
# A pool with a file system holding a 1M file, mapped by unmap.py, and the
# DTrace program running, with fsflush turned off.  $1: failmode,
# $2: primarycache, $3: which pages to dirty (all or first),
# $4: zfs_txg_timeout to set, if any.
#
function dp_setup
{
	typeset -i t
	typeset obj pf to

	dp_stop
	dp_remove_pool
	rm -f $DP_VDEV $DP_OUT $DP_DIR/dirty $DP_DIR/go $DP_DIR/expect
	pf=$(get_tunable dopageflush)
	to=$(get_tunable zfs_txg_timeout)
	[[ -n $pf && -n $to ]] || log_fail "can't read the tunables"
	dp_saved="dopageflush/W 0t$pf
zfs_txg_timeout/W 0t$to"
	echo "dopageflush/W 0" | mdb -kw >/dev/null ||
	    log_fail "can't set dopageflush"
	if [[ -n $4 ]]; then
		echo "zfs_txg_timeout/W 0t$4" | mdb -kw >/dev/null ||
		    log_fail "can't set zfs_txg_timeout"
	fi

	log_must mkfile 256m $DP_VDEV
	log_must zpool create -f -o failmode=$1 -O canmount=off $TESTPOOL \
	    $DP_VDEV
	log_must zfs create -o recordsize=128k -o compression=off \
	    -o normalization=formD -o primarycache=$2 $DP_FS
	log_must dd if=/dev/urandom of=$DP_MNT/file bs=128k count=8
	# Mount it again, so that no name cache entry holds the file.
	log_must zfs unmount $DP_FS
	log_must zfs mount $DP_FS
	obj=$(ls -i $DP_MNT/file | nawk '{ print $1 }')

	python $DP_PY $DP_MNT/file $3 $DP_DIR > $DP_DIR/unmap.out 2>&1 &
	dp_hpid=$!
	t=120
	until [[ -e $DP_DIR/dirty ]]; do
		kill -0 $dp_hpid 2>/dev/null ||
		    log_fail "unmap.py failed: $(cat $DP_DIR/unmap.out)"
		((t-- == 0)) && log_fail "unmap.py didn't map the file"
		sleep 0.5
	done

	dtrace -s $DP_D $dp_hpid $TESTPOOL $obj > $DP_OUT 2>&1 &
	dp_dpid=$!
	t=60
	until grep -q "^ready" $DP_OUT 2>/dev/null; do
		kill -0 $dp_dpid 2>/dev/null ||
		    log_fail "dtrace failed: $(cat $DP_OUT)"
		((t-- == 0)) && log_fail "dtrace didn't start"
		sleep 0.5
	done
}

#
# Slow the pool's I/O.  Sync it first, so that no txg sync from the remount
# is left to queue its writes ahead of the reads and writes we time.
#
function dp_slow # delay_ms
{
	log_must zpool sync $TESTPOOL
	log_must eval "zinject -d $DP_VDEV -D $1:1 $TESTPOOL >/dev/null"
}

#
# Stop unmap.py and DTrace, and show what DTrace saw.
#
function dp_finish
{
	dp_stop
	log_note "DTrace output:"
	cat $DP_OUT
}

#
# A forced unmount of a healthy pool, with the file unmapped while
# zil_close() waits for a syncing txg.
#
function dp_unmount
{
	typeset -li rc waited asg ta tc

	dp_setup wait all all 600
	dp_slow 300
	#
	# Dirty the open txg, and the zil, so that zil_close() waits for a
	# txg whose (delayed) writes take seconds.
	#
	log_must dd if=/dev/urandom of=$DP_MNT/other bs=128k count=8
	zfs unmount -f $DP_FS > $DP_DIR/op.out 2>&1 &
	dp_opid=$!
	if dp_wait 180 " Z syncing " " Z zil_close done"; then
		log_must touch $DP_DIR/go
		dp_wait 60 " T inactive done"
	fi
	log_must zinject -c all
	dp_wait_op 300
	rc=$?
	dp_finish
	((rc == 0)) || log_fail "zfs unmount -f failed: $(cat $DP_DIR/op.out)"

	waited=$(nawk '/ Z waits for txg / { print $6; exit }' $DP_OUT)
	asg=$(nawk '/ T assigned / { print $4; exit }' $DP_OUT)
	ta=$(dp_time " T assigned ")
	tc=$(dp_time " Z zil_close done")
	if ((waited == 0 || asg <= waited)) ||
	    ((ta == 0 || tc == 0 || ta > tc)); then
		log_note "the pages weren't written while zil_close() waited"
		dp_remove_pool
		return
	fi
	dp_hit=1
	log_note "pages written in txg $asg while zil_close() waited for" \
	    "txg $waited"
	grep -q " T log " $DP_OUT &&
	    log_fail "the pages were logged into the zil being closed"
	log_must zfs mount $DP_FS
	[[ $(sha256digest $DP_MNT/file) == $(sha256digest $DP_DIR/expect) ]] ||
	    log_fail "the pages written during the forced unmount were lost"
	dp_remove_pool
}

#
# "zpool export -F" of a failmode=death pool, while zfs_inactive()'s page
# write reads after its tx is assigned.
#
function dp_export
{
	typeset -li rc tz tr
	typeset zl

	dp_setup death metadata first
	dp_slow 5000
	log_must touch $DP_DIR/go
	# Let the read be issued, and delayed, before clearing the delay.
	dp_wait 60 " T reads" " T inactive done" && sleep 1
	log_must zinject -c all
	zpool export -F $TESTPOOL > $DP_DIR/op.out 2>&1 &
	dp_opid=$!
	dp_wait_op 300
	rc=$?
	dp_wait 60 " T inactive done"
	dp_finish
	((rc == 0)) || log_fail "zpool export -F failed: $(cat $DP_DIR/op.out)"
	log_mustnot poolexists $TESTPOOL
	mount -p | nawk -v m=$DP_MNT '$3 == m { f = 1 } END { exit !f }' &&
	    log_fail "$DP_MNT is still mounted"

	tz=$(dp_time " Z waits for the inactive lock")
	tr=$(dp_time " T read done")
	if ((tz == 0 || tr == 0 || tz > tr)); then
		log_note "the export didn't reach the file system while the" \
		    "page write was reading"
		return
	fi
	dp_hit=1
	log_note "the export waited for the page write's read"
	zl=$(nawk '/ T log / { print $4; exit }' $DP_OUT)
	[[ -n $zl && $zl != 0 ]] ||
	    log_fail "the page write wasn't logged before the zil was closed"
}

log_assert "A file system can be torn down while zfs_inactive() writes out" \
    "a file's dirty pages"
log_onexit cleanup

dp_mkfiles
for case in dp_unmount dp_export; do
	typeset -i try
	dp_hit=0
	for ((try = 1; try <= 3 && !dp_hit; try++)); do
		log_note "$case: try $try"
		$case
	done
	((dp_hit)) || log_fail "$case: the timing never worked out"
done

log_pass "A file system can be torn down while zfs_inactive() writes out" \
    "a file's dirty pages"
