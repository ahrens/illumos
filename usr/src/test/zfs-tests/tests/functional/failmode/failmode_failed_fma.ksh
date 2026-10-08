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
#	FMA diagnoses a failed pool as ZFS-8000-LR (fault.fs.zfs.pool_failed),
#	even when its disk has failed every write, retried or not, and zpool
#	status refers to ZFS-8000-LR too.  Once the pool is exported, the
#	fault no longer applies.
#
# STRATEGY:
#	1. Create a failmode=death pool on a file vdev, and make every write
#	   to the vdev fail.
#	2. Dirty the pool until it fails.
#	3. zpool status shows ZFS-8000-LR, and within 60 seconds fmadm
#	   faulty lists a ZFS-8000-LR fault for the pool.
#	4. Export the pool: the fault is no longer listed.
#

verify_runnable "global"

typeset FS=/$TESTPOOL/$TESTFS

# Whether fmadm faulty lists a ZFS-8000-LR fault for the pool, which it
# names by its GUID, in hex, once the pool is exported.
function lr_faulted # pool guid
{
	fmadm faulty 2>/dev/null | nawk -v p="zfs://pool=$1" \
	    -v g="zfs://pool=$(printf "%x" $2)" '
	    / ZFS-8000-/ { lr = ($0 ~ / ZFS-8000-LR /) }
	    lr && ($0 ~ (p "([/ ]|$)") || $0 ~ (g "([/ ]|$)")) { found = 1 }
	    END { exit !found }'
}

if [[ "$(svcs -Ho state svc:/system/fmd 2>/dev/null)" != online ]]; then
	log_unsupported "fmd isn't running"
fi

log_assert "FMA diagnoses a failed pool as ZFS-8000-LR"
log_onexit failmode_cleanup

failmode_create_pool death
typeset guid=$(zpool get -Hp -o value guid $TESTPOOL)
log_mustnot lr_faulted $TESTPOOL $guid
failmode_break_vdev
# The pool fails during the write, so the write itself may fail.
dd if=/dev/urandom of=$FS/dirty bs=128k count=64 >/dev/null 2>&1
failmode_wait_failed $TESTPOOL

log_must eval "zpool status $TESTPOOL | grep -q ZFS-8000-LR"

typeset -i tries=60
until lr_faulted $TESTPOOL $guid; do
	((tries-- == 0)) && log_fail "fmadm faulty doesn't list ZFS-8000-LR"
	sleep 1
done
log_note "$(fmadm faulty | grep ZFS-8000-LR)"

log_must zinject -c all
log_must zpool export $TESTPOOL
tries=60
while lr_faulted $TESTPOOL $guid; do
	((tries-- == 0)) && log_fail "the fault outlived the exported pool"
	sleep 1
done

log_pass "FMA diagnoses a failed pool as ZFS-8000-LR"
