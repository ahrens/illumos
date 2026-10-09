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
#	A failed pool can read its metadata only where it happens to be
#	cached, and what it reports never depends on that:
#	- its features are the ones that were enabled when it failed
#	- "zpool status" says its error count is unknown
#	- "zfs list" and .zfs/snapshot list every snapshot, or fail; they
#	  never stop early as though there were no more
# STRATEGY:
#	1. Create snapshots, then export and import the pool, so nothing
#	   has read the snapshot names.
#	2. Make writes fail, write to the file system, and wait for the
#	   pool to fail.
#	3. Check the features, the error count and the snapshot lists.
#

typeset FS=$TESTPOOL/$TESTFS
typeset -i nsnaps=5

#
# Run a command that lists the snapshots, one per line, as the given
# pattern: it must list them all or fail.  ls(1) reports an error reading
# a directory but still exits 0, so an I/O error in the output counts as
# failing too.
#
function check_snap_list # what pattern cmd...
{
	typeset what=$1 pattern=$2 out
	shift 2
	out=$("$@" 2>&1)
	typeset -i rc=$?
	log_note "$what exited $rc: $out"
	typeset -i n=$(print -r -- "$out" | grep -c "$pattern")
	if ((n != nsnaps && rc == 0)) && [[ $out != *"I/O error"* ]]; then
		log_fail "$what listed only $n of $nsnaps snapshots"
	fi
}

function enabled_features
{
	zpool get -H -o property,value all $TESTPOOL |
	    nawk '$1 ~ /^feature@/ && $2 != "disabled" { print $1 }' | sort
}

log_assert "What a failed pool reports doesn't depend on what is cached"
log_onexit failmode_cleanup

failmode_create_pool death
for ((i = 0; i < nsnaps; i++)); do
	log_must zfs snapshot $FS@snap$i
done
typeset features=$(enabled_features)
log_must test -n "$features"

log_must zpool export $TESTPOOL
log_must zpool import -d $TEST_BASE_DIR $TESTPOOL

failmode_break_vdev
log_must dd if=/dev/urandom of=/$FS/dirty bs=128k count=8
failmode_wait_failed $TESTPOOL

typeset after=$(enabled_features)
[[ "$after" == "$features" ]] ||
    log_fail "features were: $features; failed pool shows: $after"

for v in "" -v; do
	zpool status $v $TESTPOOL |
	    grep -q "^errors: Unknown, the pool has failed$" ||
	    log_fail "zpool status $v doesn't say the error count is unknown"
done

check_snap_list ".zfs/snapshot" "^snap" ls /$FS/.zfs/snapshot
check_snap_list "zfs list" "^$FS@snap" \
    zfs list -H -o name -t snapshot -d 1 $FS

log_pass "What a failed pool reports doesn't depend on what is cached"
