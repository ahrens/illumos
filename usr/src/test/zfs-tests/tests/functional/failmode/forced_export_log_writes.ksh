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
. $STF_SUITE/tests/functional/failmode/forced_export_pinned.kshlib

#
# DESCRIPTION:
#	A log write that is still in flight when a failmode=death pool
#	fails, to a device that takes its time, holds up nothing without a
#	deadline:
#	- A rollback of the mounted file system fails at once with EIO,
#	  rather than wait to suspend the file system.
#	- A forced unmount returns an error at the export's deadline, and
#	  the file system stays mounted.
#	- "zpool export" returns an error at its deadline.
#	Once the write is done, the pool exports, and every record whose
#	fsync() returned 0 is there after the pool is imported again.
#
# STRATEGY:
#	1. Create a failmode=death pool with a slog, and a writer that
#	   fsync()s 128k records in a loop.
#	2. Make the slog's writes take 90 seconds ("zinject -D"), and wait
#	   (with DTrace) for a log block write to be delayed.
#	3. Fail the pool by making the writes to its other vdevs fail.  MMP
#	   (multihost=on, with a short interval) fails it: the next txg sync
#	   would fail it only once the log block write is done, since the
#	   sync waits for the log blocks of its txg.
#	4. While the log block write is in flight, run a rollback, a forced
#	   unmount and "zpool export", each within a time limit, and check
#	   that each failed, the rollback with EIO and the unmount with EBUSY
#	   from zfs_umount().  "zfs rollback" and "umount -f" would fail
#	   before they got to the kernel, since they can't open the dataset
#	   on the failed pool, so the test calls lzc_rollback_to() and
#	   umount2() itself.  (The rollback fails before zfs_suspend_fs(),
#	   too: looking up the file system reads blocks that the failed txg
#	   dirtied, which are no longer cached.)
#	5. Wait for the writer's fsync() to fail, export the pool, import it,
#	   check the writer's records, and scrub.
#

typeset FS=$TESTPOOL/$TESTFS

function cleanup
{
	pin_cleanup
}

log_assert "A log write in flight on a failed pool doesn't hold up a" \
    "rollback, a forced unmount or the export without a deadline"
log_onexit cleanup

pin_mkwriter
pin_mkslog
pin_mkpool log $PIN_SLOG
pin_mmp_fast
log_must zfs snapshot $FS@snap
pin_writer w0 fsync
sleep 3

# Only the slog will have a delay.  MMP writes to it too, so look for a
# write of a log block.
cat > $PIN_D <<EOF
#pragma D option quiet
#pragma D option switchrate=100hz
int delayed;
BEGIN
{
	printf("ready\\n");
}
sdt:::zio-delay-hit
/!delayed && stringof(((zio_t *)arg0)->io_spa->spa_name) == "$TESTPOOL" &&
    (uintptr_t)((zio_t *)arg0)->io_logical->io_done ==
    (uintptr_t)&\`zil_lwb_write_done/
{
	delayed = 1;
	printf("log block write delayed\\n");
}
fbt::zfs_umount:return
{
	printf("%s returned %d\\n", probefunc, arg1);
}
EOF
pin_start_d

# Every write to the slog takes 90 seconds from now on.
log_must eval "zinject -d $PIN_SLOG -D 90000:16 $TESTPOOL >/dev/null"
typeset -i t=20
until grep -q "^log block write delayed" $PIN_OUT; do
	((t-- == 0)) && log_fail "no log block write was delayed"
	sleep 0.5
done

pin_fail_now

# The rollback can't change the failed pool, and fails at once.
run_within 10 "the rollback" python -c '
import ctypes, sys
lzc = ctypes.CDLL("libzfs_core.so.1")
lzc.libzfs_core_init()
sys.exit(lzc.lzc_rollback_to(sys.argv[1].encode(), sys.argv[2].encode()))
' $FS $FS@snap
log_must test $within_rc -eq 5

# The forced unmount gives up at the deadline (20 seconds).
run_within 45 "the forced unmount" python -c '
import ctypes, sys
libc = ctypes.CDLL("libc.so.1", use_errno=True)
MS_FORCE = 0x400
if libc.umount2(sys.argv[1].encode(), MS_FORCE) != 0:
	sys.exit(ctypes.get_errno())
' /$FS
log_must test $within_rc -eq 16
sleep 1
grep -q '^zfs_umount returned 16$' $PIN_OUT ||
    log_fail "the forced unmount didn't fail in zfs_umount() with EBUSY"
log_must eval "mount -p | grep -q ' /$FS zfs '"

# So does the export: the file system can't be detached either.
log_must zinject -c all
run_within 45 "zpool export" zpool export $TESTPOOL
log_mustnot test $within_rc -eq 0
log_must poolexists $TESTPOOL

kill $pin_dpid >/dev/null 2>&1
pin_dpid=""

# Once the log block write is done, the writer's fsync() fails.
t=150
while kill -0 ${pin_pids[0]} 2>/dev/null; do
	((t-- == 0)) && log_fail "the writer's fsync() didn't return"
	sleep 1
done
log_must grep -q '^err 5$' $PIN_DIR/w0.log
pin_kill_bg

# MMP that fast would fail the reimported pool if its claim took a while.
pin_mmp_restore
pin_export_failed
pin_reimport
pin_verify_writers

log_pass "A log write in flight on a failed pool doesn't hold up a" \
    "rollback, a forced unmount or the export without a deadline"
