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
#	"zpool export -F" of a suspended pool works while a volume's first
#	open waits for the pool holding zfsdev_state_lock, and the open then
#	returns.  Before it fails the pool, -F checks that the pool has no
#	volume it mustn't fail (zvol_pinned_minors()), and that check must not
#	wait for zfsdev_state_lock.  It must still find such a volume: -F of a
#	pool with a swap volume fails and leaves the pool as it was.
#
# STRATEGY:
#	1. Create a failmode=wait pool with two volumes, and add one of them
#	   as a swap device.  Check that "zpool export -F" fails and leaves
#	   the pool healthy, and remove the swap device.
#	2. Make the pool's writes fail, and start "zpool reguid", which
#	   suspends the pool and sleeps on it holding spa_namespace_lock.
#	3. Open the other volume, which isn't open, through /devices (a lookup
#	   in /dev/zvol could wait for spa_namespace_lock first), and check
#	   that its first open waits holding zfsdev_state_lock.
#	4. Check that "zpool export -fF" finishes, and that the open and the
#	   reguid return.
#	5. Import the pool, and check that the volume works.
#

typeset SWAPDEV=/dev/zvol/dsk/$TESTPOOL/swapvol
typeset -i reguid_pid=0
typeset -i open_pid=0

function cleanup
{
	typeset pid pids=""

	zinject -c all >/dev/null 2>&1
	swap -l 2>/dev/null | nawk -v dev=$SWAPDEV '$1 == dev { f = 1 }
	    END { exit !f }' && swap -d $SWAPDEV
	pool_is_suspended $TESTPOOL && zpool clear $TESTPOOL
	for pid in $reguid_pid $open_pid; do
		((pid == 0)) && continue
		kill $pid >/dev/null 2>&1
		pids="$pids $pid"
	done
	[[ -n $pids ]] && failmode_reap $pids
	failmode_cleanup
}

#
# The thread that holds a kernel mutex, or "-" if none does.
#
function mutex_owner # mutex
{
	echo "$1::mutex" | mdb -k 2>/dev/null | nawk 'NR == 2 { print $3 }'
}

#
# Is the mutex held by a thread that is asleep in the given function?
#
function mutex_held_in # mutex function
{
	typeset owner=$(mutex_owner $1)

	log_note "$1 owner: $owner"
	[[ -n $owner && $owner != "-" ]] || return 1
	echo "$owner::findstack" | mdb -k 2>/dev/null | grep -q "$2"
}

#
# Wait up to 30 seconds for a background process to exit, and return its exit
# status.
#
function wait_exit # pid description
{
	typeset -i tries=30

	while kill -0 $1 2>/dev/null; do
		if ((tries-- == 0)); then
			log_fail "$2 is still waiting"
		fi
		sleep 1
	done
	wait $1
}

log_assert "zpool export -F works while a volume's first open waits for" \
    "the pool, and still refuses a pool with a swap volume"
log_onexit cleanup

failmode_create_pool wait
log_must zfs create -V 32m $TESTPOOL/swapvol
log_must zfs create -V 32m $TESTPOOL/vol

# The open goes through /devices; find the volume's minor while we can.
typeset minor=$(ls -lL /dev/zvol/rdsk/$TESTPOOL/vol | nawk '{ print $6 }')
typeset voldev=$(ls -d /devices/pseudo/zfs@*:$minor,raw 2>/dev/null)
log_note "$TESTPOOL/vol is $voldev"
[[ -n $voldev && -c $voldev ]] || log_fail "no device for $TESTPOOL/vol"

# A swap volume pins the pool: -F refuses it, and doesn't fail it.
log_must swap -a $SWAPDEV
log_mustnot zpool export -F $TESTPOOL
log_must poolexists $TESTPOOL
log_mustnot pool_has_failed $TESTPOOL
log_must swap -d $SWAPDEV
log_must zpool sync $TESTPOOL
log_mustnot pool_has_failed $TESTPOOL

failmode_break_vdev
zpool reguid $TESTPOOL &
reguid_pid=$!
typeset -i tries=30
until pool_is_suspended $TESTPOOL; do
	if ((tries-- == 0)); then
		log_fail "pool didn't suspend"
	fi
	sleep 1
done
sleep 2
kill -0 $reguid_pid 2>/dev/null ||
    log_fail "zpool reguid didn't wait for the suspended pool"
typeset owner=$(mutex_owner spa_namespace_lock)
log_note "spa_namespace_lock owner: $owner"
[[ -n $owner && $owner != "-" ]] || log_fail "spa_namespace_lock isn't held"

dd if=$voldev of=/dev/null bs=512 count=1 >/dev/null 2>&1 &
open_pid=$!
typeset -i tries=30
until mutex_held_in zfsdev_state_lock zvol_first_open; do
	if ((tries-- == 0)); then
		log_fail "no first open waits holding zfsdev_state_lock"
	fi
	sleep 1
done
kill -0 $open_pid 2>/dev/null || log_fail "the open didn't wait"

#
# The injection handlers stay: "zinject -c" needs spa_namespace_lock too.  The
# export fails the pool, which lets zpool reguid and then the open return, and
# then waits for the handlers to go away; it gives up with EBUSY (see
# forced_export_retry).
#
run_within 60 "zpool export -fF with a volume's first open waiting" \
    zpool export -fF $TESTPOOL

wait_exit $open_pid "the volume's first open"
log_note "the open returned $?"
open_pid=0

wait_exit $reguid_pid "zpool reguid"
typeset -i rc=$?
reguid_pid=0
log_note "zpool reguid returned $rc"
# Its sync task's txg never committed.
((rc != 0)) || log_fail "zpool reguid succeeded on the failed pool"

log_must zinject -c all
if poolexists $TESTPOOL; then
	log_must pool_has_failed $TESTPOOL
	log_must zpool export -fF $TESTPOOL
fi
log_mustnot poolexists $TESTPOOL

log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
log_must dd if=/dev/zvol/rdsk/$TESTPOOL/vol of=/dev/null bs=512 count=1
log_must zpool scrub $TESTPOOL
log_must wait_scrubbed $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

log_pass "zpool export -F works while a volume's first open waits for" \
    "the pool, and still refuses a pool with a swap volume"
