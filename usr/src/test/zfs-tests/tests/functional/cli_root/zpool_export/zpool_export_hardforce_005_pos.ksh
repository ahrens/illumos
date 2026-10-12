#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.
#

#
# Copyright (c) 2025, Klara, Inc.
#

. $STF_SUITE/tests/functional/cli_root/zpool_export/zpool_export.kshlib

#
# DESCRIPTION:
# Verify that a suspended pool with non-forced export hung can be exported
# using hardforce flag.
#
# STRATEGY:
# 1. Create a pool.
# 2. Write some content to check it later.
# 3. Sync.
# 4. Create the situation with non-forced export sleeping as the pool
#    suspension happens after its start.
# 5. Forcibly export.
# 6. Verify that non-forced zpool export is not running.
# 7. Import it back.
# 8. Verify that the content written before is the same.
#

verify_runnable "global"

function cleanup
{
	# The non-forced export may still be running if the pool was slow to
	# suspend, and a hardforce export cannot start until it gives up.
	if [[ -n "$nonforced_export_pid" ]]; then
		zinject -c all
		wait $nonforced_export_pid
	fi

	# The test may fail and leave a sleeping spa_namespace_lock holder.
	# Let's unbreak it first.
	zpool export -F $TESTPOOL

	clear_suspension_artifacts $TESTPOOL
	poolexists $TESTPOOL && destroy_pool $TESTPOOL
}

log_assert "zpool export -F of a suspended pool with non-forced export hung."
log_onexit cleanup

log_must create_pool $TESTPOOL raidz $FEDISK0 $FEDISK1 $FEDISK2

FS1=fs1
FS2=fs1/fs2

log_must zfs create $TESTPOOL/$FS1
log_must zfs create $TESTPOOL/$FS2

TESTFILE1="/$TESTPOOL/$FS1/file1.dd"
log_must dd if=/dev/urandom of=$TESTFILE1 \
    oflag=sync bs=1M count=10
log_must zpool sync $TESTPOOL
TESTFILE1_CKSUM="$(sha256digest $TESTFILE1)"

TESTFILE2="/$TESTPOOL/$FS2/file2.dd"
log_must dd if=/dev/urandom of=$TESTFILE2 \
    oflag=sync bs=1M count=10
log_must zpool sync $TESTPOOL
TESTFILE2_CKSUM="$(sha256digest $TESTFILE2)"

# The idea is to use existing zinject features to make I/O slow enough
# so that non-forced export starts zfs unmounting process and while
# it waits for sync we trigger pool suspension. Then we can remove
# I/O slowdown and non-forced export is expected to sleep for
# txg_wait_synced while still working on zfs unmount.

# Slow down writing
h1=$(zinject -q -d $FEDISK0 -D 500:1 -T write $TESTPOOL)
h2=$(zinject -q -d $FEDISK1 -D 500:1 -T write $TESTPOOL)
h3=$(zinject -q -d $FEDISK2 -D 500:1 -T write $TESTPOOL)

# Add dirty data, which is not expected to quickly hit disks
# due to slowed I/O
echo hello-world >> /$TESTPOOL/$FS2/hello.txt

# Start non-forced export
zpool export $TESTPOOL &
nonforced_export_pid=$!

# Let it go deeper down to some sync wait logic
sleep 1

# Now we trigger pool suspension
zinject -d $FEDISK0 -L pad2 $TESTPOOL
zinject -d $FEDISK0 -e io -T write $TESTPOOL
zinject -d $FEDISK2 -L pad2 $TESTPOOL
zinject -d $FEDISK2 -e io -T write $TESTPOOL

# Slow I/O is not required anymore
zinject -c $h1
zinject -c $h2
zinject -c $h3

# Let it find itself in trouble
log_must wait_pool_suspended $TESTPOOL

# Check our assumption of where the non-forced export is.  On illumos a
# plain export of a suspended pool may instead give up with EAGAIN as soon
# as the pool suspends, which is also fine: it must not be stuck elsewhere.
if kill -0 $nonforced_export_pid 2>/dev/null; then
	log_must pid_stack_has $nonforced_export_pid txg_wait_synced
else
	log_note "the non-forced export already returned"
fi

# No injections required now
zinject -c all

#
# On illumos, -F fails the suspended pool, which lets the waiting plain
# export go on: it may finish the export itself before -F gets to it, and
# then -F finds no pool.  Either way, the pool must be gone and one of the
# two exports must have done it.
#
zpool export -F $TESTPOOL
typeset -i frc=$?
wait $nonforced_export_pid
typeset -i nrc=$?
nonforced_export_pid=
log_note "zpool export -F returned $frc, the plain export $nrc"
log_mustnot poolexists $TESTPOOL
((frc == 0 || nrc == 0)) || log_fail "neither export succeeded"

log_must zpool import $TESTPOOL
log_must test "$TESTFILE1_CKSUM" = "$(sha256digest $TESTFILE1)"
log_must test "$TESTFILE2_CKSUM" = "$(sha256digest $TESTFILE2)"

log_pass "zpool export -F of a suspended pool with non-forced export hung."
