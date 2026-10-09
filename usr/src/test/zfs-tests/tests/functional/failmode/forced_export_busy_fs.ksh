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

# forced_export_busy_fs_{continue,death} run this with another failmode.
typeset FE_FAILMODE=${FE_FAILMODE:-wait}

#
# DESCRIPTION:
#	"zpool export -F" of a suspended pool whose file system is busy
#	finishes: file writers waiting in fsync() or in O_DSYNC writes, a
#	writer syncing an mmap()ed file, an open file and a process whose
#	current directory is in the file system all fail out or let go, the
#	file system is unmounted, and the pool is exported.  No fsync() or
#	synchronous write that returns once the export has started returns
#	success.
#
# STRATEGY:
#	1. Start writers that each write and fsync() (or write O_DSYNC, or
#	   msync() an mmap()ed file) in a loop, logging when each sync
#	   returns and what it returned, and processes that hold a file open
#	   and sit in a directory of the file system.
#	2. Make the pool's writes fail, so that it suspends.
#	3. Run "zpool export -fF", and check that it finishes, and that every
#	   writer then stops, with no sync logged as returning success after
#	   the export started.
#	4. Import the pool and scrub it.
#

typeset FS=/$TESTPOOL/$TESTFS
typeset LOGDIR=$TEST_BASE_DIR/busy_fs_logs
typeset SYNCER=$TEST_BASE_DIR/busy_fs_syncer.py
typeset -a pids
typeset -i nwriters=0

function cleanup
{
	zinject -c all >/dev/null 2>&1
	pool_is_suspended $TESTPOOL && zpool clear $TESTPOOL
	for pid in ${pids[@]}; do
		kill -9 $pid >/dev/null 2>&1
	done
	wait
	failmode_cleanup
	rm -rf $LOGDIR $SYNCER
}

log_assert "zpool export -F of a suspended pool with a busy file system" \
    "finishes, and fails every pending sync"
log_onexit cleanup
log_note "failmode=$FE_FAILMODE"

#
# The writer: <mode> <file> <log>.  Each line of the log is the time a sync
# returned, and 0 or the errno it failed with.  The writer stops at the
# first error.
#
cat > $SYNCER <<'EOF'
import mmap, os, sys, time
mode, path, log = sys.argv[1:4]
out = open(log, "w", buffering=1)
buf = os.urandom(128 * 1024)
flags = os.O_RDWR | os.O_CREAT
if mode == "dsync":
	flags |= os.O_DSYNC
try:
	fd = os.open(path, flags, 0o644)
	if mode == "mmap":
		os.ftruncate(fd, 1024 * 1024)
		m = mmap.mmap(fd, 1024 * 1024)
except OSError as e:
	out.write("%f %d\n" % (time.time(), e.errno))
	sys.exit(0)
i = 0
while True:
	try:
		if mode == "mmap":
			m[(i % 8) * 128 * 1024:((i % 8) + 1) * 128 * 1024] = buf
			m.flush()
		else:
			os.pwrite(fd, buf, (i % 64) * 128 * 1024)
			if mode == "fsync":
				os.fsync(fd)
		out.write("%f 0\n" % time.time())
	except OSError as e:
		out.write("%f %d\n" % (time.time(), e.errno))
		break
	except (ValueError, BufferError) as e:
		out.write("%f -1\n" % time.time())
		break
	i += 1
EOF

log_must mkdir -p $LOGDIR
failmode_create_pool $FE_FAILMODE
log_must zfs set sync=standard $TESTPOOL/$TESTFS

for mode in fsync fsync dsync dsync mmap; do
	python $SYNCER $mode $FS/$mode.$nwriters $LOGDIR/$nwriters &
	pids[$nwriters]=$!
	((nwriters++))
done

# A file held open, and a process sitting in the file system.
log_must mkdir $FS/dir
log_must touch $FS/held
sleep 3600 < $FS/held &
pids[$nwriters]=$!
(cd $FS/dir && sleep 3600) &
pids[$((nwriters + 1))]=$!

# Let the writers get going.
sleep 5
for ((i = 0; i < nwriters; i++)); do
	[[ -s $LOGDIR/$i ]] || log_fail "writer $i didn't sync anything"
	kill -0 ${pids[$i]} 2>/dev/null || log_fail "writer $i stopped early"
done

failmode_break_vdev
failmode_wait_stopped $TESTPOOL $FE_FAILMODE
sleep 2

typeset start=$(python -c 'import time; print("%f" % time.time())')
log_note "export started at $start"
log_must zinject -c all
run_within 60 "zpool export -fF of the suspended pool" \
    zpool export -fF $TESTPOOL
log_must test $within_rc -eq 0
log_mustnot poolexists $TESTPOOL

# Every writer stops, and none of them synced anything after the export
# started.
for ((i = 0; i < nwriters; i++)); do
	typeset -i tries=30
	while kill -0 ${pids[$i]} 2>/dev/null; do
		if ((tries-- == 0)); then
			log_fail "writer $i is still running"
		fi
		sleep 1
	done
	nawk -v start=$start -v w=$i '
	    $1 > start && $2 == 0 { bad++ }
	    END {
		printf("writer %d: last %s\n", w, $0)
		exit (bad > 0)
	    }' $LOGDIR/$i || log_fail "writer $i synced after the export started"
	typeset rc=$(tail -1 $LOGDIR/$i | nawk '{ print $2 }')
	[[ $rc != 0 ]] || log_fail "writer $i stopped without an error"
done

# The processes with the open file and the directory are still there.
log_must kill -0 ${pids[$nwriters]}
log_must kill -0 ${pids[$((nwriters + 1))]}
kill -9 ${pids[$nwriters]} ${pids[$((nwriters + 1))]}
wait

log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
log_must zpool scrub $TESTPOOL
log_must wait_scrubbed $TESTPOOL
log_must check_pool_status $TESTPOOL "errors" "No known data errors"

log_pass "zpool export -F of a suspended pool with a busy file system" \
    "finishes, and fails every pending sync"
