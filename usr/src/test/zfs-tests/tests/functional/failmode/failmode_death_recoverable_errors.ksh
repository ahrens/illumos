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
#	A failmode=death pool fails only where a failmode=wait pool would
#	suspend.  I/O errors that ZFS recovers from by itself, and read errors
#	that it reports to the reader, leave the pool running: synchronous
#	writes keep succeeding, and the pool neither fails nor suspends.
#	Failing it would throw away its unsynced changes and take it out of
#	service for an error it had already handled.
#
# STRATEGY:
#	For each kind of error, on a new death pool on a file vdev whose
#	cache was emptied by an export and import, with an fsync writer and
#	an O_DSYNC writer running for 10 seconds:
#	- failfast: the first attempt of every read and write fails
#	  (zinject -F), and the retry, which zinject leaves alone, succeeds.
#	  Data read from the disk comes back intact.
#	- flush: every cache flush fails (zinject -T ioctl), so the ZIL
#	  falls back to waiting for txgs to sync.
#	- dataio, datacksum: every read of one file's data fails with EIO
#	  or a checksum error (zinject -t data).  Reading the file, and a
#	  scrub, get the error; nothing else does.
#	Then: no sync write failed, the pool hasn't failed or suspended, it
#	still syncs, and (failfast, flush) it is still healthy.  Clear the
#	injection, export and import the pool, and check its data, and that
#	a scrub finds no errors.
#
#	Intermittent write errors aren't tested: a write in place in a late
#	sync pass isn't reexecuted, so one failure suspends a failmode=wait
#	pool, and a death pool has to fail.
#

verify_runnable "global"

typeset RES=$TEST_BASE_DIR/recoverable
typeset -a wpids

#
# Write 128k blocks synchronously (mode fsync or dsync) for the given number
# of seconds, and leave "<writes> <failures>" in the result file.
#
function sync_writer # mode file seconds result
{
	typeset flags="conv=notrunc,fsync"
	[[ $1 == dsync ]] && flags="conv=notrunc oflag=dsync"
	typeset -i end=$((SECONDS + $3)) n=0 bad=0

	while ((SECONDS < end)); do
		gnu_dd if=/dev/urandom of=$2 bs=128k count=1 \
		    seek=$((n % 64)) $flags >/dev/null 2>&1 || ((bad++))
		((n++))
	done
	echo "$n $bad" > $4
}

function cleanup
{
	typeset p

	for p in ${wpids[@]}; do
		kill $p >/dev/null 2>&1
	done
	failmode_reap ${wpids[@]}
	failmode_cleanup
	rm -f $RES.*
}

log_assert "A failmode=death pool survives errors that ZFS recovers from"
log_onexit cleanup

for kind in failfast flush dataio datacksum; do
	log_note "errors: $kind"
	failmode_create_pool death
	typeset fs=$(get_prop mountpoint $TESTPOOL/$TESTFS)
	log_must dd if=/dev/urandom of=$fs/cold bs=128k count=64
	log_must dd if=/dev/urandom of=$fs/victim bs=128k count=16
	# The first sync write creates the log, with a txg wait.
	log_must gnu_dd if=/dev/zero of=$fs/w0 bs=128k count=1 conv=fsync
	log_must gnu_dd if=/dev/zero of=$fs/w1 bs=128k count=1 conv=fsync
	sync_pool $TESTPOOL
	typeset cold=$(sha256digest $fs/cold)
	log_must zpool export $TESTPOOL
	log_must zpool import -d $TEST_BASE_DIR $TESTPOOL

	case $kind in
	failfast)
		log_must zinject -d $FAILMODE_VDEV -F -e io -T all $TESTPOOL ;;
	flush)
		log_must zinject -d $FAILMODE_VDEV -e io -T ioctl $TESTPOOL ;;
	dataio)
		log_must zinject -t data -e io $fs/victim ;;
	datacksum)
		log_must zinject -t data -e checksum $fs/victim ;;
	esac

	sync_writer fsync $fs/w0 10 $RES.w0 &
	wpids[0]=$!
	sync_writer dsync $fs/w1 10 $RES.w1 &
	wpids[1]=$!

	case $kind in
	failfast)
		log_must test "$cold" = "$(sha256digest $fs/cold)" ;;
	dataio|datacksum)
		# Not cat: it maps the file, and writing to /dev/null
		# never touches the pages.
		log_mustnot dd if=$fs/victim of=/dev/null bs=128k
		log_must zpool scrub -w $TESTPOOL ;;
	esac

	wait ${wpids[@]}
	wpids=()
	for w in w0 w1; do
		read n bad < $RES.$w
		log_note "$kind: $w did $n sync writes, $bad failed"
		((n > 0)) || log_fail "$kind: $w did no sync writes"
		((bad == 0)) || log_fail "$kind: $bad sync writes failed"
	done
	log_mustnot pool_has_failed $TESTPOOL
	log_mustnot pool_is_suspended $TESTPOOL
	log_must gnu_dd if=/dev/urandom of=$fs/after bs=128k count=1 conv=fsync
	sync_pool $TESTPOOL
	if [[ $kind == failfast || $kind == flush ]]; then
		typeset health=$(zpool get -H -o value health $TESTPOOL)
		[[ $health == ONLINE ]] ||
		    log_fail "$kind: the pool is $health: $(zpool status $TESTPOOL)"
	fi

	log_must zinject -c all
	log_must zpool export $TESTPOOL
	log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
	log_must test "$cold" = "$(sha256digest $fs/cold)"
	log_must test -f $fs/after
	log_must zpool scrub -w $TESTPOOL
	log_must check_pool_status $TESTPOOL "errors" "No known data errors"
	failmode_cleanup
done

log_pass "A failmode=death pool survives errors that ZFS recovers from"
