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
# On illumos, zpool export -F of a healthy pool is an ordinary export: it
# arms the pool, so that a write error from then on fails it, but it does
# not cut off a running receive.  A healthy pool with a receive running is
# busy.
#
# STRATEGY:
# 1. Initiate a send from one pool and receive to another pool.
# 2. Slow the send using pv, so it blocks a normal pool export.
# 3. Check that normal export fails.
# 4. Check that zpool export -F fails too, and the receive keeps going.
# 5. Stop the receive; zpool export -F now succeeds.
# 6. Verify pool is no longer present in the list output.
#

verify_runnable "global"

[[ -x /usr/bin/pv ]] || log_unsupported "pv is not installed"

function cleanup
{
	[[ -n "$sendpid" ]] && kill -9 "$sendpid"
	[[ -n "$recvpid" ]] && kill -9 "$recvpid"
	[[ -n "$pvpid" ]] && kill -9 $pvpid
	poolexists $TESTPOOL2 && destroy_pool $TESTPOOL2
	[[ -n "$file0" ]] && rm -f "$file0"
	poolexists $TESTPOOL && destroy_pool $TESTPOOL

	# The pool is left exported, not destroyed; clear its labels.
	labelclear_disks $FEDISK0 $FEDISK1 $FEDISK2
}
log_onexit cleanup

log_assert "zpool export -F of a healthy pool doesn't interrupt a receive."

mkdir -p $TESTDIR
dstsnap=$TESTPOOL/$TESTFS@$TESTSNAP
srcsnap=$TESTPOOL2/$TESTFS@$TESTSNAP
sendfifo=$TESTDIR/sendfifo.$$
recvfifo=$TESTDIR/recvfifo.$$
file0=$TESTDIR/file0.$$

log_must create_pool $TESTPOOL raidz $FEDISK0 $FEDISK1 $FEDISK2

log_must truncate -s 1G $file0
log_must create_pool $TESTPOOL2 $file0
log_must zfs create $TESTPOOL2/$TESTFS
log_must dd if=/dev/urandom of=/$TESTPOOL2/$TESTFS/$TESTFILE1 bs=1M count=128
log_must zfs snapshot $srcsnap

log_must mkfifo $sendfifo
log_must mkfifo $recvfifo
zfs send $srcsnap > $sendfifo &
sendpid=$!
pv -L 1M < $sendfifo > $recvfifo &
pvpid=$!
zfs recv $dstsnap < $recvfifo &
recvpid=$!

log_note "zfs send pid is $sendpid, pv pid is $pvpid, recv pid is $recvpid"

log_note "Waiting until zfs receive has a chance to start ..."
for i in {1..5}; do
	zfs list $TESTPOOL/$TESTFS && break
	sleep 1
done
log_must zfs list $TESTPOOL/$TESTFS

# Send & receive should still be running; non-forced export should yield.
log_must kill -0 $sendpid
log_must kill -0 $recvpid
log_mustnot zpool export $TESTPOOL

# Send should still be running; force export should yield too.
log_must kill -0 $sendpid
log_must kill -0 $recvpid
log_mustnot zpool export -F $TESTPOOL
log_must kill -0 $sendpid
log_must kill -0 $recvpid

# Once the receive is gone, the export goes through.
kill $sendpid $pvpid $recvpid
wait $sendpid $pvpid $recvpid
sendpid=
pvpid=
recvpid=
log_must zpool export -F $TESTPOOL

poolexists $TESTPOOL && \
	log_fail "$TESTPOOL unexpectedly found in 'zpool list' output."

log_pass "zpool export -F of a healthy pool doesn't interrupt a receive."
