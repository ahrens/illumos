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
#	"zpool export -F" doesn't refuse a pool because of a failed swap
#	volume of an earlier pool of the same name.  The export of a failed
#	pool fails its swap volume, which stays open while swap holds it, but
#	no longer holds any pool.
#
# STRATEGY:
#	1. Create a failmode=death pool with a volume, and add the volume as
#	   a swap device, by its /devices path, which outlasts the pool.
#	2. Make the pool's writes fail, write to it, and wait for it to fail.
#	   Export it, which fails the swap volume.
#	3. Create a new pool of the same name on another file.
#	4. Check that "zpool export -F" exports the new pool.
#	5. Remove the swap device, and check that it and the failed volume's
#	   minor are gone.
#

typeset VDEV2=$TEST_BASE_DIR/failed_swap_vdev2
typeset SWAPDEV=""
typeset -i sync_pid=0

function swap_listed # device
{
	swap -l 2>/dev/null | nawk -v dev=$1 '$1 == dev { f = 1 }
	    END { exit !f }'
}

#
# Does the minor still have the volume's soft state?
#
function minor_exists # minor volume
{
	typeset f1='::printf "%d %p\n" zfs_soft_state_t zss_type zss_data'
	typeset f2='::printf "%s\n" zvol_state_t zv_name'
	typeset ss=$(print -r -- "*zfsdev_state::softstate 0t$1 | $f1" |
	    mdb -k 2>/dev/null)

	# A volume's soft state is ZSST_ZVOL (0).
	[[ -n $ss && ${ss%% *} == 0 ]] || return 1
	[[ $(print -r -- "${ss##* }$f2" | mdb -k 2>/dev/null) == $2 ]]
}

function cleanup
{
	zinject -c all >/dev/null 2>&1
	((sync_pid != 0)) && failmode_reap $sync_pid
	if [[ -n $SWAPDEV ]] && swap_listed $SWAPDEV; then
		swap -d $SWAPDEV || log_note "couldn't remove swap device $SWAPDEV"
	fi
	failmode_cleanup
	rm -f $VDEV2
}

log_assert "zpool export -F doesn't refuse a pool for a failed swap volume" \
    "of an earlier pool of the same name"
log_onexit cleanup

# 1. A failmode=death pool with a swap volume.
failmode_create_pool death
log_must zfs create -V 32m $TESTPOOL/swapvol
typeset minor=$(ls -lL /dev/zvol/dsk/$TESTPOOL/swapvol | nawk '{ print $6 }')
SWAPDEV=$(ls -d /devices/pseudo/zfs@*:$minor 2>/dev/null)
log_note "$TESTPOOL/swapvol is $SWAPDEV"
[[ -n $SWAPDEV && -b $SWAPDEV ]] || log_fail "no device for $TESTPOOL/swapvol"
log_must swap -a $SWAPDEV

# 2. Fail the pool, and export it, which fails the swap volume.
failmode_break_vdev
dd if=/dev/urandom of=/$TESTPOOL/$TESTFS/file bs=128k count=8 >/dev/null 2>&1
zpool sync $TESTPOOL >/dev/null 2>&1 &
sync_pid=$!
failmode_wait_failed $TESTPOOL
failmode_reap $sync_pid
sync_pid=0
log_must zinject -c all
log_must zpool export $TESTPOOL
log_mustnot poolexists $TESTPOOL
log_must swap_listed $SWAPDEV

# 3. A new pool of the same name.
log_must mkfile $MINVDEVSIZE $VDEV2
log_must zpool create -f $TESTPOOL $VDEV2

# 4. The failed swap volume doesn't pin the new pool.
log_must zpool export -F $TESTPOOL
log_mustnot poolexists $TESTPOOL

# 5. The swap device can still be removed.
log_must swap -d $SWAPDEV
log_mustnot swap_listed $SWAPDEV
typeset -i tries=10
while minor_exists $minor $TESTPOOL/swapvol; do
	((tries-- == 0)) && log_fail "the failed volume's minor is still there"
	sleep 1
done

log_pass "zpool export -F doesn't refuse a pool for a failed swap volume" \
    "of an earlier pool of the same name"
