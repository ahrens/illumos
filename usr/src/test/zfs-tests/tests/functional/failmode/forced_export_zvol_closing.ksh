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

# forced_export_zvol_closing_continue runs this with failmode=continue.
typeset FE_FAILMODE=${FE_FAILMODE:-wait}

#
# DESCRIPTION:
#	The last close of a volume on a suspended pool waits for the pool
#	without holding zfsdev_state_lock, and "zpool export -F" finishes
#	while it waits: the pool fails during the close, the close returns,
#	and the volume's minor goes away.  While the close waits, opens of
#	another pool's volume, and that pool's export and import, each finish
#	within 5 seconds, and an open of the closing volume waits for the
#	close and then returns.
#
# STRATEGY:
#	1. Create a second pool with a volume, and the test pool with a
#	   volume.
#	2. Open the test pool's volume, turn on its write cache, so that its
#	   writes are logged but not committed, write to it, and sync the
#	   pool, so that it is idle when the suspension's write errors start.
#	3. Suspend the test pool, close the volume, and check that the close
#	   waits.  It waits although the volume's data has synced, since
#	   closing its log commits it.
#	4. Start an open of the closing volume through its block device, and
#	   check that it waits.
#	5. Check that an open of the other pool's volume, and the other
#	   pool's export and import, each finish within 5 seconds.
#	6. Run "zpool export -fF" of the test pool, and check that it, the
#	   close and the waiting open finish, and that the volume's minor is
#	   gone.
#	7. Import the test pool, and check that the volume works.
#

typeset OTHER_DIR=$TEST_BASE_DIR/fe_zvol_closing_dir
typeset OTHER_VOL=/dev/zvol/rdsk/$TESTPOOL1/othervol
typeset VOL=/dev/zvol/rdsk/$TESTPOOL/vol
typeset WRITER=$TEST_BASE_DIR/fe_zvol_closing_writer.py
typeset STATUS=$TEST_BASE_DIR/fe_zvol_closing.status
typeset GO=$TEST_BASE_DIR/fe_zvol_closing.go
typeset -i writer_pid=0
typeset -i open_pid=0

function cleanup
{
	typeset pid pids=""

	touch $GO
	zinject -c all >/dev/null 2>&1
	pool_is_suspended $TESTPOOL && zpool clear $TESTPOOL
	for pid in $writer_pid $open_pid; do
		((pid == 0)) && continue
		kill -9 $pid >/dev/null 2>&1
		pids="$pids $pid"
	done
	[[ -n $pids ]] && failmode_reap $pids
	if ! poolexists $TESTPOOL1 && [[ -f $OTHER_DIR/vdev ]]; then
		zpool import -d $OTHER_DIR $TESTPOOL1 >/dev/null 2>&1
	fi
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	if ! poolexists $TESTPOOL && [[ -f $FAILMODE_VDEV ]]; then
		zpool import -d $TEST_BASE_DIR $TESTPOOL >/dev/null 2>&1
	fi
	failmode_cleanup
	rm -rf $OTHER_DIR $WRITER $STATUS $GO
}

#
# Does the volume still have the minor?  This asks the kernel: /devices can
# keep a removed minor's node for a while.  (See forced_export_zvol.)
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

log_assert "zpool export -F finishes while a volume's last close waits for" \
    "the suspended pool, and other volumes and pools aren't held up"
log_onexit cleanup
log_note "failmode=$FE_FAILMODE"

#
# The writer: <device> <status> <go>.  It turns on the volume's write cache
# (DKIOCSETWCE), writes 1 MB, logs "written", waits for <go> to exist, closes
# the volume, and logs "closed".
#
cat > $WRITER <<'EOF'
import fcntl, os, struct, sys, time
dev, status, go = sys.argv[1], sys.argv[2], sys.argv[3]
DKIOCSETWCE = (0x04 << 8) | 37
out = open(status, "w", buffering=1)
fd = os.open(dev, os.O_RDWR)
fcntl.ioctl(fd, DKIOCSETWCE, struct.pack("i", 1))
buf = os.urandom(128 * 1024)
for i in range(8):
	os.pwrite(fd, buf, i * 128 * 1024)
out.write("written\n")
while not os.path.exists(go):
	time.sleep(0.1)
os.close(fd)
out.write("closed\n")
EOF

rm -f $STATUS $GO
log_must mkdir -p $OTHER_DIR
log_must mkfile $MINVDEVSIZE $OTHER_DIR/vdev
log_must zpool create -f $TESTPOOL1 $OTHER_DIR/vdev
log_must zfs create -V 16m $TESTPOOL1/othervol

failmode_create_pool $FE_FAILMODE
log_must zfs create -V 16m $TESTPOOL/vol
typeset minor=$(ls -lL $VOL | nawk '{ print $6 }')
typeset voldev=$(ls -d /devices/pseudo/zfs@*:$minor,raw 2>/dev/null)
typeset volblk=${voldev%,raw}
log_note "$TESTPOOL/vol has minor $minor, $voldev"
[[ -n $voldev && -c $voldev && -b $volblk ]] || \
    log_fail "no devices for $TESTPOOL/vol"

python $WRITER $VOL $STATUS $GO &
writer_pid=$!
typeset -i tries=30
until grep -q written $STATUS 2>/dev/null; do
	if ((tries-- == 0)) || ! kill -0 $writer_pid 2>/dev/null; then
		log_fail "the writer didn't write to $TESTPOOL/vol"
	fi
	sleep 1
done
sync_pool $TESTPOOL

failmode_suspend_pool
touch $GO
sleep 3
grep -q closed $STATUS && log_fail "the last close didn't wait for the pool"
kill -0 $writer_pid 2>/dev/null || log_fail "the writer exited"

#
# An open of the closing volume waits for the close (zvol_wait_close()).  It
# opens the block device: specfs holds opens of the character device that the
# writer is closing until that close returns, so they would never reach the
# driver.  It goes through /devices: a lookup in /dev/zvol could wait for the
# suspended pool first.
#
dd if=$volblk of=/dev/null bs=128k count=1 >/dev/null 2>&1 &
open_pid=$!
sleep 2
kill -0 $open_pid 2>/dev/null || log_fail "the open didn't wait for the close"

#
# None of these waits for the closing volume, whose close doesn't hold
# zfsdev_state_lock: the open and close of another volume, and the other
# pool's export, which removes that pool's minors (zvol_remove_minors()).
#
run_within 5 "open of another pool's volume" \
    dd if=$OTHER_VOL of=/dev/null bs=128k count=1
log_must test $within_rc -eq 0
run_within 5 "zpool export of another pool" zpool export $TESTPOOL1
log_must test $within_rc -eq 0
run_within 5 "zpool import of another pool" \
    zpool import -d $OTHER_DIR $TESTPOOL1
log_must test $within_rc -eq 0
grep -q closed $STATUS && log_fail "the last close didn't wait for the pool"

#
# The export fails the pool, which ends the close's waits.  The export
# doesn't wait for the close itself (zvol_fail_minors() skips the volume),
# only for it to let go of the pool.
#
log_must zinject -c all
run_within 90 "zpool export -fF with a last close waiting" \
    zpool export -fF $TESTPOOL
log_must test $within_rc -eq 0
log_mustnot poolexists $TESTPOOL

wait_exit $writer_pid "the writer's close"
typeset -i rc=$?
writer_pid=0
log_note "the writer returned $rc"
((rc == 0)) || log_fail "the writer failed"
grep -q closed $STATUS || log_fail "the writer didn't log its close"

wait_exit $open_pid "the open of the closing volume"
log_note "the open of the closing volume returned $?"
open_pid=0

typeset -i tries=10
while minor_exists $minor $TESTPOOL/vol; do
	if ((tries-- == 0)); then
		log_fail "the minor of $TESTPOOL/vol is still there"
	fi
	sleep 1
done

log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
typeset -i tries=30
until dd if=/dev/urandom of=$VOL bs=128k count=8 >/dev/null 2>&1; do
	if ((tries-- == 0)); then
		log_fail "$TESTPOOL/vol doesn't work after the import"
	fi
	sleep 1
done
log_must zpool scrub $TESTPOOL
log_must wait_scrubbed $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

log_pass "zpool export -F finishes while a volume's last close waits for" \
    "the suspended pool, and other volumes and pools aren't held up"
