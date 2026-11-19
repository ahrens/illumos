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
#	A pool that fails while it is being imported isn't imported: the
#	import fails with EIO and leaves no pool behind, and the pool imports
#	later as it was.  A failmode=death pool whose first txg can't be
#	written fails by itself.  A failmode=wait pool suspends, and the
#	import waits for it until "zpool export -F" fails it.  (An import
#	that went on with the failed pool would panic a DEBUG kernel when it
#	restarted initialize and TRIM.)
#
# STRATEGY:
#	The pool we import, $TESTPOOL1, is on a file in $TESTPOOL, which has
#	a slog.  The import must be able to write to the file when it opens
#	the pool, since each leaf's probe writes to it, and its first txg
#	must fail before the import is done loading, which is when the
#	import waits for the txg to sync because it claimed log blocks.  So
#	$TESTPOOL1 is exported frozen, with log blocks to claim, and the
#	slog's writes are slow: the first txg's first cache flush, an
#	fsync() of the file, waits for one.  We then fail $TESTPOOL (as
#	"zpool export -F" does before it exports), after which writes to the
#	file fail at once.  For each failmode:
#	1. Create $TESTPOOL1, write a file to it, freeze it, write a log
#	   record, and export it
#	2. Make $TESTPOOL's slog take 20 seconds per write, import $TESTPOOL1
#	   in the background, and wait (with DTrace) for a log block write of
#	   $TESTPOOL to be delayed: the import's first flush
#	3. Fail $TESTPOOL.  For failmode=wait, once $TESTPOOL1 has suspended,
#	   run "zpool export -F $TESTPOOL1"
#	4. The import fails with EIO within 60 seconds, and $TESTPOOL1 isn't
#	   imported
#	5. Export $TESTPOOL, and import it: $TESTPOOL1 imports with its file
#	   intact, and a scrub finds no errors
#

verify_runnable "global"

typeset DIR=$TEST_BASE_DIR/forced_export_import
typeset VDEVS=$DIR/vdevs
typeset FS=$TESTPOOL/$TESTFS
typeset INNER_VDEV=/$FS/inner_vdev
typeset IMPORT_OUT=$DIR/import.out
typeset FEXIT=$DIR/fexit.py
typeset DSYNC=$DIR/dsync.py
typeset D=$DIR/delay.d
typeset D_OUT=$DIR/delay.out
typeset -i import_pid=0
typeset -i dpid=0

function cleanup
{
	typeset -i pid
	typeset p

	# Fail $TESTPOOL1, in case an import of it waits for it to resume.
	zpool export -F $TESTPOOL1 >/dev/null 2>&1 &
	pid=$!
	zinject -c all >/dev/null 2>&1
	failmode_reap $pid
	if ((import_pid != 0)); then
		failmode_reap $import_pid
		import_pid=0
	fi
	((dpid != 0)) && kill $dpid >/dev/null 2>&1
	dpid=0
	for p in $TESTPOOL1 $TESTPOOL; do
		if poolexists $p && pool_has_failed $p; then
			zpool export -f $p
		elif poolexists $p; then
			destroy_pool $p
		fi
	done
	rm -rf $DIR
}

log_assert "A pool that fails while it is being imported isn't imported"
log_onexit cleanup

log_must mkdir -p $VDEVS

cat > $FEXIT <<'EOF'
# fexit.py <pool>: fail the pool, as "zpool export -F" does before it
# exports it.
import ctypes, sys
z = ctypes.CDLL("libzfs.so.1")
z.libzfs_init.restype = ctypes.c_void_p
h = ctypes.c_void_p(z.libzfs_init())
sys.exit(z.zpool_force_exit_name(h, sys.argv[1].encode(), 0))
EOF

cat > $DSYNC <<'EOF'
# dsync.py <file> <count>: write count 8k records with O_DSYNC.
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_DSYNC)
for i in range(int(sys.argv[2])):
	os.write(fd, b"%d" % i * 8192)
EOF

# A log block write of $TESTPOOL that zinject delays.
cat > $D <<EOF
#pragma D option quiet
#pragma D option switchrate=100hz
BEGIN
{
	printf("ready\\n");
}
sdt:::zio-delay-hit
/stringof(((zio_t *)arg0)->io_spa->spa_name) == "$TESTPOOL" &&
    (uintptr_t)((zio_t *)arg0)->io_logical->io_done ==
    (uintptr_t)&\`zil_lwb_write_done/
{
	printf("log block write delayed\\n");
	exit(0);
}
EOF

for mode in death wait; do
	log_note "failmode=$mode"
	log_must mkfile $MINVDEVSIZE $VDEVS/vdev $VDEVS/slog
	log_must zpool create -f $TESTPOOL $VDEVS/vdev log $VDEVS/slog
	log_must zfs create -o atime=off $FS
	log_must mkfile -n $MINVDEVSIZE $INNER_VDEV
	log_must zpool create -o failmode=$mode $TESTPOOL1 $INNER_VDEV
	log_must dd if=/dev/urandom of=/$TESTPOOL1/data bs=128k count=8
	typeset cksum=$(sha256digest /$TESTPOOL1/data)

	# A log record that only the log has, for the import to claim.  The
	# first sync write puts the log on disk before the freeze.
	log_must python $DSYNC /$TESTPOOL1/first 1
	log_must zpool sync $TESTPOOL1
	log_must zpool freeze $TESTPOOL1
	log_must python $DSYNC /$TESTPOOL1/log 8
	log_must zpool export $TESTPOOL1
	log_must zpool sync $TESTPOOL

	dtrace -s $D > $D_OUT 2>&1 &
	dpid=$!
	typeset -i tries=40
	until grep -q "^ready" $D_OUT 2>/dev/null; do
		if ! kill -0 $dpid 2>/dev/null; then
			cat $D_OUT
			log_fail "dtrace failed"
		fi
		((tries-- == 0)) && log_fail "dtrace didn't start"
		sleep 0.5
	done

	log_must eval "zinject -d $VDEVS/slog -D 20000:1 $TESTPOOL >/dev/null"
	zpool import -d /$FS $TESTPOOL1 >$IMPORT_OUT 2>&1 &
	import_pid=$!

	tries=60
	until grep -q "^log block write delayed" $D_OUT; do
		if ((tries-- == 0)); then
			log_fail "the import's flush didn't wait for the slog"
		fi
		if ! kill -0 $import_pid 2>/dev/null; then
			log_fail "the import finished before it flushed"
		fi
		sleep 0.5
	done
	dpid=0

	# From now on, every write to $TESTPOOL1's file fails.
	log_must python $FEXIT $TESTPOOL

	if [[ $mode == wait ]]; then
		log_note "waiting for $TESTPOOL1 to suspend"
		tries=60
		until pool_is_suspended $TESTPOOL1; do
			if ((tries-- == 0)); then
				log_fail "$TESTPOOL1 didn't suspend"
			fi
			if ! kill -0 $import_pid 2>/dev/null; then
				log_fail "the import didn't wait for $TESTPOOL1"
			fi
			sleep 1
		done

		# The export fails the pool, and by the time it can look the
		# pool up, the failed import has removed it.
		run_within 60 "zpool export -F of the pool being imported" \
		    zpool export -F $TESTPOOL1
	fi

	tries=60
	while kill -0 $import_pid 2>/dev/null; do
		if ((tries-- == 0)); then
			log_fail "the import of the failed pool didn't return"
		fi
		sleep 1
	done
	wait $import_pid
	typeset -i rc=$?
	import_pid=0
	log_note "zpool import returned $rc: $(<$IMPORT_OUT)"
	if ((rc == 0)); then
		log_fail "the import of the failed pool succeeded"
	fi
	# The import itself failed, with EIO because the pool failed, rather
	# than importing the failed pool and failing to mount its file
	# systems.
	log_must grep -q "cannot import '$TESTPOOL1': I/O error" $IMPORT_OUT
	log_mustnot poolexists $TESTPOOL1

	# Nothing reached the file: the pool is as it was exported.
	log_must zinject -c all
	run_within 60 "zpool export -f of the failed pool" \
	    zpool export -f $TESTPOOL
	log_must test $within_rc -eq 0
	log_must zpool import -d $VDEVS $TESTPOOL
	log_must zpool import -d /$FS $TESTPOOL1
	log_must test "$cksum" = "$(sha256digest /$TESTPOOL1/data)"
	log_must zpool scrub -w $TESTPOOL1
	log_must check_pool_status $TESTPOOL1 "errors" "No known data errors"
	log_must zpool destroy $TESTPOOL1
	log_must zpool destroy $TESTPOOL
	rm -f $VDEVS/vdev $VDEVS/slog
done

log_pass "A pool that fails while it is being imported isn't imported"
