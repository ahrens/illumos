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
#	"zfs create" fails, rather than panicking the system, when it can't
#	read its parent's normalization, utf8only and casesensitivity
#	properties.  The new file system takes them from its parent's master
#	node.  The read fails on a checksum or I/O error, and on a failed
#	pool whenever the block isn't cached.
#
# STRATEGY:
#	1. Create a file system that is never mounted, so that nothing reads
#	   its master node.  Disable embedded_data, so that the master node
#	   is stored in a block of its own.
#	2. Turn off the dbuf caches, and import the pool without mounting.
#	3. Inject read errors on the master node, flush the ARC, and create
#	   a file system in it.  The create must fail, after a failed read
#	   of its parent's properties.
#	4. Clear the injection, and check that the create now succeeds.
#

. $STF_SUITE/include/libtest.shlib

verify_runnable "global"

DISK=${DISKS%% *}
PARENT=$TESTPOOL/parent
DBUF_CACHE=$(get_tunable dbuf_cache_max_bytes)
DBUF_MD_CACHE=$(get_tunable dbuf_metadata_cache_max_bytes)

function cleanup
{
	zinject -c all >/dev/null 2>&1
	set_tunable64 dbuf_cache_max_bytes $DBUF_CACHE >/dev/null
	set_tunable64 dbuf_metadata_cache_max_bytes $DBUF_MD_CACHE >/dev/null
	destroy_pool $TESTPOOL
}

log_assert "zfs create fails if it can't read its parent's properties"
log_onexit cleanup

log_must zpool create -f -o feature@embedded_data=disabled $TESTPOOL $DISK
log_must zfs create -o canmount=off $PARENT
sync_pool $TESTPOOL
typeset objset=$(get_prop objsetid $PARENT)

log_must zpool export $TESTPOOL
log_must set_tunable64 dbuf_cache_max_bytes 0
log_must set_tunable64 dbuf_metadata_cache_max_bytes 0
log_must zpool import -N $TESTPOOL
log_must zinject -b $(printf "%x:1:0:0" $objset) $TESTPOOL
log_must zinject -a

#
# Without the fix, the failed read panics the system.  Print the exit
# status of "zfs create", and how many of its reads of the parent's
# properties failed.
#
typeset out=$(dtrace -q \
    -n 'fbt:zfs:zfs_get_zplprop:return /pid == $target && arg1 != 0/ {n++;}' \
    -n 'syscall::rexit:entry /pid == $target/ { rc = arg0; }' \
    -n 'END { printf("%d %d\n", rc, n); }' \
    -c "zfs create $PARENT/child" 2>&1)
log_note "zfs create (exit status, failed reads): $out"
set -- $(echo "$out" | tail -1)
(($# == 2)) || log_fail "dtrace failed: $out"
(($1 != 0)) || log_fail "zfs create succeeded"
(($2 > 0)) || log_fail "zfs create didn't fail to read its parent's properties"
datasetexists $PARENT/child && log_fail "$PARENT/child exists"

log_must zinject -c all
log_must zfs create $PARENT/child

log_pass "zfs create fails if it can't read its parent's properties"
