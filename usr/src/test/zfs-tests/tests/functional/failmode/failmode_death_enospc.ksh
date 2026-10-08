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
#	A failmode=death pool that runs out of space in syncing context
#	fails, as it does for any other reason it would suspend: a suspended
#	pool can't free space, since that takes a txg.  It can be exported,
#	and imports at its last committed txg, consistent.
#
# STRATEGY:
#	The DMU keeps the pool from filling up, so we make it think that the
#	pool is much bigger than it is, by adding to the space of its normal
#	allocation class.  The txg sync then fails to allocate.
#	1. The pool fails within 60 seconds, without suspending
#	2. zpool export removes it
#	3. It imports, and a scrub finds no errors
#

typeset FS=/$TESTPOOL/$TESTFS
typeset -li EXTRA=$((1024 * 1024 * 1024 * 1024))
typeset dd_pid=""
typeset -i added=0

#
# Add to the deflated space of the pool's normal class.
#
function adjust_class_space # delta
{
	typeset mc_dspace
	typeset spa=$(echo "::spa" | mdb -k |
	    nawk -v pool=$TESTPOOL '$NF == pool { print $1 }')
	[[ -n $spa ]] || log_fail "can't find spa_t for $TESTPOOL"
	typeset mc=$(echo "$spa::print -d spa_t spa_normal_class" | mdb -k |
	    nawk '{ print $NF }')
	mc_dspace=$(echo "$mc::print -a metaslab_class_t mc_dspace" | mdb -k |
	    nawk '{ print $1 }')
	typeset -li old=$(echo "$mc_dspace/E" | mdb -k |
	    nawk 'NF > 1 { print $2 }')
	typeset -li new=$((old + $1))
	log_note "mc_dspace $old -> $new"
	echo "$mc_dspace/Z 0t$new" | mdb -kw >/dev/null ||
	    log_fail "can't write mc_dspace"
	((added += $1))
}

function cleanup
{
	[[ -n $dd_pid ]] && kill $dd_pid >/dev/null 2>&1
	# metaslab_class_destroy() asserts that the class has no space left.
	if poolexists $TESTPOOL && ((added != 0)); then
		adjust_class_space -$added
	fi
	if poolexists $TESTPOOL && pool_is_suspended $TESTPOOL; then
		zpool export -fF $TESTPOOL
		rm -f $FAILMODE_VDEV
	fi
	failmode_cleanup
}

log_assert "A failmode=death pool that runs out of space fails"
log_onexit cleanup

failmode_create_pool death
log_must zfs set compression=off sync=disabled $TESTPOOL/$TESTFS
adjust_class_space $EXTRA

# Write more than fits, in the background: it fails once the pool does.
dd if=/dev/urandom of=$FS/fill bs=1024k count=$((2 * MINVDEVSIZE / 1048576)) \
    >/dev/null 2>&1 &
dd_pid=$!

typeset -i tries=60
until pool_has_failed $TESTPOOL; do
	if ((tries-- == 0)); then
		log_fail "pool didn't fail"
	fi
	if pool_is_suspended $TESTPOOL; then
		log_fail "pool suspended when it ran out of space"
	fi
	sleep 1
done
wait $dd_pid
dd_pid=""

# Take back the space we added: the pool's metaslabs account for the rest
# as they go, and metaslab_class_destroy() asserts that none is left.
adjust_class_space -$EXTRA
run_within 60 "zpool export of the failed pool" zpool export $TESTPOOL
log_must test $within_rc -eq 0
log_mustnot poolexists $TESTPOOL

log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
log_must zpool scrub $TESTPOOL
log_must wait_scrubbed $TESTPOOL
log_must zpool status -v $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

log_pass "A failmode=death pool that runs out of space fails"
