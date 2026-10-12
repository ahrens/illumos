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
# A suspended pool with a running send should be hardforce exportable.
#
# STRATEGY:
# 1. Initiate a send from pool to a file, with nothing cached.
# 2. Slow the send using pv, so it blocks a normal pool export.
# 3. Suspend the pool.
# 4. Check that normal export fails.
# 5. Forcibly export pool, which fails it: the send's next read gets EIO.
# 6. Verify pool is no longer present in the list output.
#

verify_runnable "global"

[[ -x /usr/bin/pv ]] || log_unsupported "pv is not installed"

function cleanup
{
	# The test may fail and leave a sleeping spa_namespace_lock holder.
	# Let's unbreak it first.
	zpool export -F $TESTPOOL

	clear_suspension_artifacts $TESTPOOL

	[[ -n "$sendpid" ]] && kill -9 "$sendpid"
	[[ -n "$pvpid" ]] && kill -9 $pvpid
	[[ -n "$snapstream" ]] && rm -f "$snapstream"
	poolexists $TESTPOOL && destroy_pool $TESTPOOL

	# The pool is left exported, not destroyed; clear its labels.
	labelclear_disks $FEDISK0 $FEDISK1 $FEDISK2
}
log_onexit cleanup

log_assert "Verify a suspended pool can be forcibly exported while sending."

mkdir -p $TESTDIR
snap=$TESTPOOL/$TESTFS@$TESTSNAP
snapfifo=$TESTDIR/snapfifo.$$
snapstream=$TESTDIR/send.$$

log_must create_pool $TESTPOOL raidz $FEDISK0 $FEDISK1 $FEDISK2
log_must zfs create $TESTPOOL/$TESTFS
log_must dd if=/dev/urandom of=/$TESTPOOL/$TESTFS/$TESTFILE1 bs=1M count=128
log_must zfs snapshot $snap

# Start with nothing cached, so that the send has to read from the disks.
log_must zpool export $TESTPOOL
log_must zpool import $TESTPOOL

# Create FIFOs for the send, so the processes can be controlled and
# monitored individually.
log_must mkfifo $snapfifo
zfs send $snap > $snapfifo &
sendpid=$!
pv -L 1M < $snapfifo > $snapstream &
pvpid=$!

log_note "zfs send pid is $sendpid, pv pid is $pvpid"

# Send should still be running.
log_must kill -0 $sendpid
log_must kill -0 $pvpid

log_must suspend_pool $TESTPOOL $FEDISK0 $FEDISK2

# Non-forced export should yield.
log_mustnot zpool export $TESTPOOL

# Send should still be running; now try force export.
log_must kill -0 $sendpid
log_must kill -0 $pvpid
#
# zpool export -F fails the suspended pool.  It then waits up to 20 seconds
# for the pool's users to let go before giving up with EBUSY; a send that
# is blocked on its pipe notices only at its next read that misses the
# cache, so run it again, as sled-agent does, until it goes through.
#
typeset -i tries=0
until zpool export -F $TESTPOOL; do
	((++tries < 6)) || log_fail "zpool export -F still failing"
	log_must pool_has_failed $TESTPOOL
done
log_note "zpool export -F succeeded after $tries retries"

# Send should have exited with non-zero.
log_mustnot wait $sendpid
log_must wait $pvpid

poolexists $TESTPOOL && \
	log_fail "$TESTPOOL unexpectedly found in 'zpool list' output."

log_pass "Successfully forcibly exported a suspended pool while sending."
