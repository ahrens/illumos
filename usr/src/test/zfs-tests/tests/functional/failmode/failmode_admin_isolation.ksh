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
#	A suspended pool must not block administration of other pools.
#	Commands on the suspended pool itself must return rather than hang:
#	in particular "zpool export" must fail instead of waiting forever
#	for a txg while holding spa_namespace_lock, which would block every
#	later zpool and zfs command on the system.
#

typeset OTHER_VDEV=$TEST_BASE_DIR/failmode_vdev_other
typeset OTHER_DIR=$TEST_BASE_DIR/failmode_import_dir

function cleanup
{
	zinject -c all >/dev/null 2>&1
	pool_is_suspended $TESTPOOL && zpool clear $TESTPOOL
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	if ! poolexists $TESTPOOL1 && [[ -f $OTHER_DIR/vdev ]]; then
		zpool import -d $OTHER_DIR $TESTPOOL1 >/dev/null 2>&1 &&
		    destroy_pool $TESTPOOL1
	fi
	rm -rf $OTHER_VDEV $OTHER_DIR
	failmode_cleanup
}

#
# Run a command in the background and fail the test if it hasn't finished
# within 30 seconds. Sets "bounded_rc" to the command's exit status.
#
function run_bounded # description command...
{
	typeset desc=$1
	shift

	"$@" >/dev/null 2>&1 &
	typeset -i pid=$!
	typeset -i tries=30
	while kill -0 $pid 2>/dev/null; do
		if ((tries-- == 0)); then
			log_fail "$desc did not finish within 30s"
		fi
		sleep 1
	done
	wait $pid
	bounded_rc=$?
	log_note "$desc returned $bounded_rc"
}

log_assert "A suspended pool does not block administration of other pools"
log_onexit cleanup

log_must mkdir -p $OTHER_DIR
log_must mkfile $MINVDEVSIZE $OTHER_DIR/vdev
log_must zpool create -f $TESTPOOL1 $OTHER_DIR/vdev
log_must zfs create $TESTPOOL1/$TESTFS1

#
# With failmode=wait the export would block logging its history entry, as
# any other write would.
#
failmode_create_pool continue

#
# "zpool export" unmounts the pool's filesystems before it asks the kernel
# to export the pool, and unmounting a filesystem on a suspended pool still
# waits forever in zil_commit().  Unmount them first so the export reaches
# the kernel, and dirty the pool with a property change instead of a write.
# That sync task can't finish until the pool resumes.
#
log_must zfs unmount $TESTPOOL/$TESTFS
log_must zfs unmount $TESTPOOL
log_must zinject -d $FAILMODE_VDEV -e io -T write $TESTPOOL
log_must zinject -d $FAILMODE_VDEV -L pad2 $TESTPOOL
zfs set user:dirty=1 $TESTPOOL &
typeset -i dirty_pid=$!
typeset -i tries=30
until pool_is_suspended $TESTPOOL; do
	if ((tries-- == 0)); then
		log_fail "pool didn't suspend"
	fi
	sleep 1
done

# Commands on the suspended pool return instead of hanging.
run_bounded "zpool status of the suspended pool" zpool status $TESTPOOL
run_bounded "zpool list of the suspended pool" zpool list $TESTPOOL
run_bounded "zpool export of the suspended pool" zpool export $TESTPOOL
log_must test $bounded_rc -ne 0
log_must poolexists $TESTPOOL

# Administration of the other pool still works.
run_bounded "zpool list" zpool list
run_bounded "zpool status of another pool" zpool status $TESTPOOL1
log_must test $bounded_rc -eq 0
run_bounded "zpool get of another pool" zpool get all $TESTPOOL1
log_must test $bounded_rc -eq 0
run_bounded "zfs create in another pool" zfs create $TESTPOOL1/new
log_must test $bounded_rc -eq 0
run_bounded "zfs snapshot in another pool" zfs snapshot $TESTPOOL1/new@snap
log_must test $bounded_rc -eq 0
run_bounded "zfs destroy in another pool" zfs destroy -r $TESTPOOL1/new
log_must test $bounded_rc -eq 0
run_bounded "zpool export of another pool" zpool export $TESTPOOL1
log_must test $bounded_rc -eq 0
run_bounded "zpool import of another pool" \
    zpool import -d $OTHER_DIR $TESTPOOL1
log_must test $bounded_rc -eq 0

failmode_resume_pool
log_must wait $dirty_pid

log_pass "A suspended pool does not block administration of other pools"
