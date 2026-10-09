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

# forced_export_zvol_{continue,death} run this with another failmode.
typeset FE_FAILMODE=${FE_FAILMODE:-wait}

#
# DESCRIPTION:
#	"zpool export -F" of a suspended pool with open volumes, a regular one
#	and a raw one, both being written, finishes while they are still open.
#	Their writes then fail (none succeeds once the export has started),
#	their minors stay until they are closed and then go away, and the pool
#	can be imported again, with new minors for its volumes.
#
# STRATEGY:
#	1. Create a pool on a disk (raw volumes need one), with a regular
#	   volume and a raw one, and wait for the raw one to be initialized.
#	2. Start a writer on each volume that writes in a loop (O_DSYNC for
#	   the regular one), logging when each write returns and what it
#	   returned, and keeps the volume open after the first error.
#	3. Make the pool's writes fail, so that it suspends, and run
#	   "zpool export -fF".
#	4. Check that the export finishes, that the writers' writes failed,
#	   and that the minors go away when the writers exit.
#	5. Import the pool, and check that its volumes work.
#

typeset DISK=${DISKS%% *}
typeset LOGDIR=$TEST_BASE_DIR/fe_zvol_logs
typeset WRITER=$TEST_BASE_DIR/fe_zvol_writer.py
typeset -a pids
typeset -a vols=(vol rawvol)

function cleanup
{
	zinject -c all >/dev/null 2>&1
	pool_is_suspended $TESTPOOL && zpool clear $TESTPOOL
	for pid in ${pids[@]}; do
		kill -9 $pid >/dev/null 2>&1
	done
	wait
	poolexists $TESTPOOL || zpool import $TESTPOOL >/dev/null 2>&1
	poolexists $TESTPOOL && destroy_pool $TESTPOOL
	rm -rf $LOGDIR $WRITER
}

#
# The minor number of a volume's device.
#
function vol_minor # volume
{
	ls -lL /dev/zvol/rdsk/$1 | nawk '{ print $6 }'
}

#
# Does the volume still have the minor?  This asks the kernel: /devices can
# keep a removed minor's node for a while.  /dev/zfs opens take minors from
# the same space, so a removed volume's minor can be reused at once.
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

log_assert "zpool export -F of a suspended pool with open volumes finishes"
log_onexit cleanup
log_note "failmode=$FE_FAILMODE"

#
# The writer: <device> <dsync> <log>.  Each line of the log is the time a
# write returned and 0 or the errno it failed with.  After the first error
# it keeps the device open until it is killed.
#
cat > $WRITER <<'EOF'
import os, sys, time
dev, dsync, log = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
out = open(log, "w", buffering=1)
flags = os.O_RDWR | (os.O_DSYNC if dsync else 0)
fd = os.open(dev, flags)
buf = os.urandom(128 * 1024)
i = 0
while True:
	try:
		os.pwrite(fd, buf, (i % 256) * 128 * 1024)
		out.write("%f 0\n" % time.time())
	except OSError as e:
		out.write("%f %d\n" % (time.time(), e.errno))
		break
	i += 1
time.sleep(3600)
EOF

log_must mkdir -p $LOGDIR
log_must zpool create -f -o failmode=$FE_FAILMODE $TESTPOOL $DISK
log_must zfs create -V 64m $TESTPOOL/vol
log_must zfs create -V 64m -o rawvol=on $TESTPOOL/rawvol

# A raw volume is unavailable until it has been initialized.
typeset -i tries=120
until dd if=/dev/zvol/rdsk/$TESTPOOL/rawvol of=/dev/null bs=512 count=1 \
    >/dev/null 2>&1; do
	if ((tries-- == 0)); then
		log_fail "the raw volume wasn't initialized"
	fi
	sleep 1
done

typeset -a minors
for ((i = 0; i < ${#vols[@]}; i++)); do
	minors[$i]=$(vol_minor $TESTPOOL/${vols[$i]})
	log_note "${vols[$i]} has minor ${minors[$i]}"
	python $WRITER /dev/zvol/rdsk/$TESTPOOL/${vols[$i]} \
	    $((i == 0)) $LOGDIR/$i &
	pids[$i]=$!
done

sleep 5
for ((i = 0; i < ${#vols[@]}; i++)); do
	[[ -s $LOGDIR/$i ]] || log_fail "the ${vols[$i]} writer wrote nothing"
	kill -0 ${pids[$i]} 2>/dev/null ||
	    log_fail "the ${vols[$i]} writer stopped early"
done

log_must zinject -d $DISK -e io -T write $TESTPOOL
log_must zinject -d $DISK -L pad2 $TESTPOOL
failmode_wait_stopped $TESTPOOL $FE_FAILMODE
sleep 2

typeset start=$(python -c 'import time; print("%f" % time.time())')
log_note "export started at $start"
log_must zinject -c all
run_within 90 "zpool export -fF of the suspended pool" \
    zpool export -fF $TESTPOOL
log_must test $within_rc -eq 0
log_mustnot poolexists $TESTPOOL

#
# Each writer's writes failed, and the writer still has its volume open.  No
# synchronous write to the regular volume succeeded after the export started
# (they all wait while the pool is suspended).  The raw volume's writes go
# straight to the disk, which works, so they succeed until the pool fails.
#
for ((i = 0; i < ${#vols[@]}; i++)); do
	typeset -i tries=30
	until [[ $(tail -1 $LOGDIR/$i | nawk '{ print $2 }') != 0 ]]; do
		if ((tries-- == 0)); then
			log_fail "the ${vols[$i]} writer's writes didn't fail"
		fi
		sleep 1
	done
	((i == 0)) && ! nawk -v start=$start '$1 > start && $2 == 0 { bad++ }
	    END { exit (bad > 0) }' $LOGDIR/$i &&
	    log_fail "a write to ${vols[$i]} succeeded after the export started"
	log_note "${vols[$i]}: $(tail -1 $LOGDIR/$i)"
	kill -0 ${pids[$i]} 2>/dev/null ||
	    log_fail "the ${vols[$i]} writer exited"
	minor_exists ${minors[$i]} $TESTPOOL/${vols[$i]} ||
	    log_fail "the minor of ${vols[$i]} went away while it was open"
done

# The minors go away at the last close.
for ((i = 0; i < ${#vols[@]}; i++)); do
	kill -9 ${pids[$i]}
	wait ${pids[$i]}
	typeset -i tries=10
	while minor_exists ${minors[$i]} $TESTPOOL/${vols[$i]}; do
		if ((tries-- == 0)); then
			log_fail "the minor of ${vols[$i]} is still there" \
			    "after its close"
		fi
		sleep 1
	done
done
unset pids

log_must zpool import $TESTPOOL
for vol in ${vols[@]}; do
	typeset -i tries=120
	until dd if=/dev/urandom of=/dev/zvol/rdsk/$TESTPOOL/$vol bs=128k \
	    count=8 >/dev/null 2>&1; do
		if ((tries-- == 0)); then
			log_fail "$vol doesn't work after the import"
		fi
		sleep 1
	done
done
log_must zpool scrub $TESTPOOL
log_must wait_scrubbed $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

log_pass "zpool export -F of a suspended pool with open volumes finishes"
