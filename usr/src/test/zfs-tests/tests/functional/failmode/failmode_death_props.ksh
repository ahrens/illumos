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
#	"zpool get" of a failed pool never shows a wrong value for a property
#	it can't read.  The properties kept in the pool's property object
#	that the kernel also keeps in memory show the values in effect; the
#	rest show "-", with a source of "-", even though the property object
#	is still cached.  The properties that come from the config are
#	unaffected.
#

function check_prop # prop value source
{
	typeset got=$(zpool get -H -o value,source $1 $TESTPOOL)
	log_note "$1: $got"
	[[ $got == "$2	$3" ]] ||
	    log_fail "$1 is \"$got\", expected \"$2	$3\""
}

log_assert "zpool get of a failed pool shows what it can't read as unknown"
log_onexit failmode_cleanup

failmode_create_pool death
log_must zpool set autoexpand=on $TESTPOOL
log_must zpool set listsnapshots=on $TESTPOOL
log_must zpool set autoreplace=on $TESTPOOL
log_must zpool set ashift=12 $TESTPOOL
log_must zpool set comment=failmode_props $TESTPOOL
sync_pool $TESTPOOL

check_prop listsnapshots on local
check_prop ashift 12 local

failmode_break_vdev
log_must dd if=/dev/urandom of=/$TESTPOOL/$TESTFS/dirty bs=128k count=8
failmode_wait_failed $TESTPOOL

check_prop health FAILED -
check_prop comment failmode_props local
check_prop failmode death local
check_prop autoexpand on local
check_prop delegation on default
check_prop autotrim off default
check_prop listsnapshots - -
check_prop autoreplace - -
check_prop ashift - -
check_prop bootfs - -

log_pass "zpool get of a failed pool shows what it can't read as unknown"
