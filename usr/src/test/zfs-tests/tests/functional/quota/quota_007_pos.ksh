#!/bin/ksh -p
#
# CDDL HEADER START
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
# CDDL HEADER END
#

#
# Copyright 2026 Oxide Computer Company
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/quota/quota.kshlib

#
# DESCRIPTION:
#
# A dataset that is using more space than its quota (which can happen
# because ZFS allows a write to overshoot the quota by up to one
# transaction group's worth of space) can still have its quota set to
# its current value, or relaxed (increased) to a value that is still
# less than the space used.  It cannot, however, have its quota
# tightened (decreased) to a value below the space used.
#
# STRATEGY:
# 1) Apply a quota to a ZFS file system and fill it, so that the
#    space used is slightly more than the quota.
# 2) Verify that the quota can be set to its current value.
# 3) Verify that the quota can be relaxed to a value that is still
#    less than the space used.
# 4) Verify that the quota can be relaxed to exactly the space used.
# 5) Verify that the quota cannot be tightened to a value below the
#    space used.
#

verify_runnable "both"

log_assert "Verify that the quota can always be relaxed, even when over quota"

#
# cleanup to be used internally as otherwise quota assertions cannot be
# run independently or out of order
#
function cleanup
{
	[[ -e $TESTDIR/$TESTFILE1 ]] && \
	    log_must rm $TESTDIR/$TESTFILE1
	#
	# Need to allow time for space to be released back to
	# pool, otherwise next test will fail trying to set a
	# quota which is less than the space used.
	#
	wait_freeing $TESTPOOL
	sync_pool $TESTPOOL
}

log_onexit cleanup

#
# Fill the quota so that the dataset is left using more space than
# its quota allows.
#
log_must fill_quota $TESTPOOL/$TESTFS $TESTDIR

typeset -i cur_quota=$(get_prop quota $TESTPOOL/$TESTFS)
typeset -i cur_used=$(get_prop used $TESTPOOL/$TESTFS)

(( cur_used <= cur_quota )) && \
    log_fail "Expected space used ($cur_used) to exceed quota ($cur_quota)"

#
# Setting the quota to its current value should succeed, even though
# the dataset is over quota, since doing so doesn't make anything
# worse.
#
log_must zfs set quota=$cur_quota $TESTPOOL/$TESTFS

#
# Relaxing the quota to a value that is still less than the space
# used should also succeed.
#
typeset -i overshoot=$(( cur_used - cur_quota ))
typeset -i relaxed_quota=$(( cur_quota + overshoot / 2 ))
(( relaxed_quota <= cur_quota )) && (( relaxed_quota = cur_quota + 1 ))
log_must zfs set quota=$relaxed_quota $TESTPOOL/$TESTFS

#
# Relaxing the quota further, to exactly the space used, should
# also succeed.
#
log_must zfs set quota=$cur_used $TESTPOOL/$TESTFS

#
# Tightening the quota to a value below the space used should
# continue to fail.
#
typeset -i tight_quota=$(( cur_used - 1 ))
log_mustnot zfs set quota=$tight_quota $TESTPOOL/$TESTFS

log_pass "The quota can always be relaxed, even when over quota"
