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
#	"zpool export -F" of an idle pool whose only device has vanished
#	finishes, with no zinject handlers involved: the device is a lofi
#	device removed out from under the pool, so its I/O fails with ENXIO
#	and the vdev is seen as removed.  (forced_export_idle is the same
#	test with injected errors.)  Run for each failmode.
#
# STRATEGY:
#	1. Create a pool on a lofi device, write some data and sync it
#	2. Forcibly remove the lofi device (lofiadm -f -d)
#	3. zpool export -F must finish within 60 seconds and remove the pool
#	4. Attach the file again and import: the data synced before is
#	   intact and a scrub finds no errors
#

verify_runnable "global"

LOFI_FILE=$TEST_BASE_DIR/lofi_vdev
LOFI_DIR=$TEST_BASE_DIR/lofi_dir
typeset lofidev=

function cleanup
{
	poolexists $TESTPOOL && zpool export -f $TESTPOOL
	[[ -n $lofidev ]] && lofiadm -f -d $lofidev
	lofidev=
	poolexists $TESTPOOL && destroy_pool $TESTPOOL
	rm -rf $LOFI_FILE $LOFI_DIR
}

log_assert "zpool export -F of an idle pool on a vanished lofi device finishes"
log_onexit cleanup

for mode in wait continue death; do
	log_note "failmode=$mode"
	log_must mkfile $MINVDEVSIZE $LOFI_FILE
	lofidev=$(lofiadm -a $LOFI_FILE) || log_fail "lofiadm -a failed"
	log_must zpool create -f -o failmode=$mode $TESTPOOL $lofidev
	log_must zfs create $TESTPOOL/$TESTFS
	typeset fs=$(get_prop mountpoint $TESTPOOL/$TESTFS)
	log_must dd if=/dev/urandom of=$fs/data bs=128k count=32
	sync_pool $TESTPOOL
	typeset cksum=$(sha256digest $fs/data)

	log_must lofiadm -f -d $lofidev
	lofidev=

	run_within 60 "zpool export -F of the pool on a vanished device" \
	    zpool export -F $TESTPOOL
	log_must test $within_rc -eq 0
	log_mustnot poolexists $TESTPOOL

	# The device comes back: everything synced before is there.
	lofidev=$(lofiadm -a $LOFI_FILE) || log_fail "lofiadm -a failed"
	log_must mkdir -p $LOFI_DIR
	log_must ln -sf $lofidev $LOFI_DIR/vdev
	log_must zpool import -d $LOFI_DIR $TESTPOOL
	log_must test "$cksum" = "$(sha256digest $fs/data)"
	log_must zpool scrub -w $TESTPOOL
	log_must check_pool_status $TESTPOOL "errors" "No known data errors"
	log_must destroy_pool $TESTPOOL
	log_must lofiadm -d $lofidev
	lofidev=
	rm -rf $LOFI_FILE $LOFI_DIR
done

log_pass "zpool export -F of an idle pool on a vanished lofi device finishes"
