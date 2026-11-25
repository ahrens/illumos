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

#
# DESCRIPTION:
#	A mount that can't read the file system's root directory fails, and
#	tears down what it set up before the read: the property callbacks,
#	the log, and the vnodes that log replay left in the name cache.
#	Otherwise the dataset keeps callbacks for the freed file system, and
#	a DEBUG kernel panics in dsl_dataset_evict_async() or zfsvfs_free().
#
# STRATEGY:
#	1. Create two file systems under a parent with dnodesize=16k, so
#	   that each root directory's dnode is alone in its block of the
#	   meta-dnode.  The objects that the mount reads before the root
#	   directory are in other blocks.
#	2. Freeze the pool, and create, rename and remove files in a
#	   subdirectory of the second file system, so that mounting it
#	   replays them.
#	3. Export the pool and import it without mounting, so that nothing
#	   has read the root directories' dnodes.
#	4. Inject read errors on those blocks, flush the ARC, and check that
#	   mounting either file system fails.
#	5. Clear the injection, and check that both mount, and that the log
#	   was replayed.
#
#	This test detects the bug only on a DEBUG kernel, where it relies on
#	the assertions in list_destroy().
#

. $STF_SUITE/include/libtest.shlib

verify_runnable "global"

DISK=${DISKS%% *}
FS=$TESTPOOL/fs
REPLAYFS=$TESTPOOL/replay

function cleanup
{
	zinject -c all >/dev/null 2>&1
	destroy_pool $TESTPOOL
}

#
# Print the zinject bookmark of the meta-dnode block that holds a file
# system's root directory, after checking that no other object is in it.
# Each block holds 32 dnode slots.
#
function root_bookmark # fs
{
	typeset objset=$(get_prop objsetid $1)
	typeset root=$(zdb -dddd $1 1 | nawk '$1 == "ROOT" {print $3}')
	[[ -n $objset && -n $root ]] || log_fail "cannot find the root of $1"
	typeset blk=$((root / 32))
	typeset n=$(zdb -dd $1 | nawk -v blk=$blk \
	    '$1 ~ /^[0-9]+$/ && $1 > 0 && $1 < 2^63 && int($1 / 32) == blk' | \
	    wc -l)
	(( n == 1 )) || log_fail "root object $root of $1 shares its block"
	printf "%x:0:0:%x" $objset $blk
}

log_assert "A mount that can't read its root directory fails cleanly"
log_onexit cleanup

log_must zpool create -f -O dnodesize=16k $TESTPOOL $DISK
log_must zfs create $FS
log_must zfs create $REPLAYFS
typeset dir=$(get_prop mountpoint $REPLAYFS)/dir
log_must mkdir $dir
# Write a ZIL header, so that the frozen pool logs the changes below.
log_must dd if=/dev/zero of=$dir/sync oflag=dsync,sync bs=1 count=1
sync_pool $TESTPOOL

log_must zpool freeze $TESTPOOL
for f in a b c d; do
	log_must touch $dir/$f
done
log_must mv $dir/a $dir/e
log_must rm $dir/b
log_must zfs unmount $REPLAYFS
log_must zfs unmount $FS

typeset fsbm=$(root_bookmark $FS)
typeset replaybm=$(root_bookmark $REPLAYFS)
log_note "root bookmarks: $FS $fsbm, $REPLAYFS $replaybm"

log_must zpool export $TESTPOOL
log_must zpool import -N $TESTPOOL
log_must zinject -b $fsbm $TESTPOOL
log_must zinject -b $replaybm $TESTPOOL
log_must zinject -a

log_mustnot zfs mount $FS
log_mustnot zfs mount $REPLAYFS

log_must zinject -c all
log_must zfs mount $FS
log_must zfs mount $REPLAYFS
log_must ismounted $FS
log_must ismounted $REPLAYFS
[[ $(ls $dir) == "$(printf "c\nd\ne\nsync")" ]] || \
    log_fail "$REPLAYFS did not replay its log: $(ls $dir)"

log_pass "A mount that can't read its root directory fails cleanly"
