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

#
# DESCRIPTION:
#	The dirty pages of a file that is no longer open or mapped, and that
#	can't be written because its owner is over quota, don't keep the
#	file system from being unmounted.  They are thrown away.
#
# STRATEGY:
#	1. Write a file, and set its owner's quota below what it uses, so
#	   that its pages can't be written back (EDQUOT).
#	2. Dirty every page through a shared mapping, then unmap and close
#	   the file without msync().
#	3. Unmount the file system: this releases the file's last hold (its
#	   name cache entry), and must succeed rather than return EBUSY.
#	4. Mount it again: the file has its old contents.
#

verify_runnable "global"

typeset FS=$TESTPOOL/$TESTFS/unwritable
typeset FILE

function cleanup
{
	datasetexists $FS && destroy_dataset $FS -r
}

log_assert "Dirty pages that can't be written don't keep a file system busy"
log_onexit cleanup

log_must zfs create $FS
FILE=$(get_prop mountpoint $FS)/file
log_must dd if=/dev/urandom of=$FILE bs=1024k count=8
log_must sync_pool $TESTPOOL
typeset sum=$(sha256digest $FILE)

log_must zfs set userquota@$(id -un)=1m $FS
log_must sync_pool $TESTPOOL

log_must mmap_dirty $FILE
log_must zfs unmount $FS
log_must zfs mount $FS
log_must test "$(sha256digest $FILE)" == "$sum"

log_pass "Dirty pages that can't be written don't keep a file system busy"
