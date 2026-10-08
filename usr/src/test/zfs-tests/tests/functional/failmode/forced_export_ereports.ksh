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
#	Once a pool has failed, its I/O posts no ereports of its own: the
#	pool posts one io_failure ereport (spa_fail()), and nothing for each
#	I/O.  The reads that were waiting in the vdev queue when the pool
#	failed are dropped by the fence, and so are their retries.  Each of
#	them would otherwise post an io ereport, and each logical read a data
#	ereport.  The reads that were already in the device come back long
#	after the failure, and each would otherwise post a delay ereport.  The
#	dropped reads are poisoned (zfs:0:forced_exit:poisoned_reads), and
#	their readers get EIO.
#
#	Writes aren't covered.  The fence completes most of the writes it
#	drops as successes, which have nothing to report; a write that it
#	fails (a CANFAIL one queued before the failure, such as a log block),
#	or that comes back late, goes through the same zio_done() gate as
#	these reads.
#
# STRATEGY:
#	1. Create a failmode=death pool with a file, export and import it to
#	   empty the caches, and read the file's first block, so that only its
#	   other data blocks are left uncached.
#	2. Hold every I/O to the vdev in the device for 20 seconds
#	   ("zinject -D"), with zio_slow_io_ms at 10 seconds.  Start one reader
#	   per block, each on its own block, for 40 more blocks than
#	   zfs_vdev_sync_read_max_active.  The first ones are issued to the
#	   device and held there, and the other 40 wait in the vdev queue.
#	3. With DTrace counting the pool's ereports, its I/O and its poisoned
#	   blocks, "zpool export -F" the pool while the reads are held, and
#	   clear the injection.  When the held reads come back, the queued
#	   ones are issued into the fence and fail, as do their retries, and
#	   are poisoned.
#	4. Check that this happened: no I/O failed or came back late before
#	   the failure; after it, the file's blocks were poisoned (DTrace and
#	   the kstat), as many leaf and logical reads failed, and held reads
#	   came back slower than zio_slow_io_ms; and every reader of a
#	   poisoned block got an error.
#	5. Check that the pool posted exactly one ereport, io_failure, both in
#	   the kernel (DTrace) and in fmd's error log, which has no io, data,
#	   checksum or delay ereport from the failed pool.
#

verify_runnable "global"

if [[ "$(svcs -Ho state svc:/system/fmd 2>/dev/null)" != online ]]; then
	log_unsupported "fmd isn't running"
fi

typeset FS=/$TESTPOOL/$TESTFS
typeset FILE=$FS/file
typeset D=$TEST_BASE_DIR/forced_export_ereports.d
typeset DOUT=$TEST_BASE_DIR/forced_export_ereports.out
typeset EERR=$TEST_BASE_DIR/forced_export_ereports.err

# How long the device holds each I/O, and the slow-I/O threshold meanwhile.
typeset -i DELAY_MS=20000
typeset -i SLOW_MS=10000
# The reads left waiting in the vdev queue when the pool fails.
typeset -i NQUEUED=40

typeset -i txg_timeout=$(get_tunable zfs_txg_timeout)
typeset -i slow_io_ms=$(get_tunable zio_slow_io_ms)
typeset -i prefetch=$(get_tunable zfs_prefetch_disable)
typeset -i nactive=$(get_tunable zfs_vdev_sync_read_max_active)
typeset -i NREADS=$((nactive + NQUEUED))
typeset -a rpids
typeset dpid="" epid=""

# The mountpoints of the pool's file systems that are mounted, deepest first.
function pool_mounts
{
	mount -p | nawk -v p=$TESTPOOL '
	    $4 == "zfs" && ($1 == p || index($1, p "/") == 1) { print $3 }' |
	    sort -r
}

# The number of I/Os in the pool's vdev queues, waiting or issued.
function in_device
{
	typeset -i w=$(kstat_pool $TESTPOOL wcnt)
	typeset -i r=$(kstat_pool $TESTPOOL rcnt)

	echo $((w + r))
}

#
# The number of this pool's ereports of the given classes (an ERE for what
# follows "ereport.fs.zfs.") that fmd has logged since the pool failed:
# those carry pool_failed.  Earlier tests' pools had the same name, so
# callers compare counts.
#
function failed_ereports # classes
{
	fmdump -e -N "pool=^$TESTPOOL\$;pool_failed=1" 2>/dev/null |
	    nawk -v re="^ereport[.]fs[.]zfs[.]($1)\$" '
	    $NF ~ re { n++ }
	    END { print n + 0 }'
}

#
# The sum of the counts in the DTrace output (see below) on the lines that
# start with the given fields.
#
function dcount # field...
{
	nawk -v want="$*" '
	    BEGIN { n = split(want, w, " ") }
	    {
		for (i = 1; i <= n; i++)
			if ($i != w[i])
				next
		sum += $NF
	    }
	    END { print sum + 0 }' $DOUT
}

function cleanup
{
	typeset pid m

	zinject -c all >/dev/null 2>&1
	[[ -n $dpid ]] && kill -TERM $dpid >/dev/null 2>&1
	for pid in ${rpids[@]}; do
		kill -9 $pid >/dev/null 2>&1
	done
	# A read held in the device can't be interrupted; it comes back.
	failmode_reap $dpid $epid ${rpids[@]}
	set_tunable32 zio_slow_io_ms $slow_io_ms
	set_tunable32 zfs_txg_timeout $txg_timeout
	set_tunable32 zfs_prefetch_disable $prefetch
	for m in $(pool_mounts); do
		umount -f $m >/dev/null 2>&1
	done
	failmode_cleanup
	rm -f $D $DOUT $EERR
}

log_assert "A failed pool posts one io_failure ereport, and none for each" \
    "of its I/Os"
log_onexit cleanup

failmode_create_pool death
log_must zfs set atime=off compression=off $TESTPOOL/$TESTFS
# Reader i reads block 4 * i: the gaps keep the vdev queue from aggregating.
log_must dd if=/dev/urandom of=$FILE bs=128k count=$((4 * NREADS + 4))
typeset -i objset=$(get_prop objsetid $TESTPOOL/$TESTFS)
typeset -i obj=$(ls -i $FILE | nawk '{ print $1 }')
log_note "$FILE is object $obj in objset $objset"

# Nothing is prefetched: each reader reads its own block, and no other.
log_must set_tunable32 zfs_prefetch_disable 1
log_must zpool export $TESTPOOL
log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
# Reading block 0 caches the file's metadata, its indirect block included.
log_must dd if=$FILE of=/dev/null bs=128k count=1
sync_pool $TESTPOOL
typeset -i tries=20
until (($(in_device) == 0)); do
	((tries-- == 0)) && log_fail "the pool's I/O didn't settle"
	sleep 0.5
done

log_must set_tunable32 zio_slow_io_ms $SLOW_MS
#
# The export of a failed pool waits for its file system's readers, whose
# reads are held in the device, until TXG_SIZE * zfs_txg_timeout seconds
# have passed (spa_exit_deadline()).
#
log_must set_tunable32 zfs_txg_timeout 15

#
# Count, for this pool ($$1):
# - the ereports it posts (by class), before and after it fails;
# - its leaf I/Os as they complete, by type, before and after it fails:
#   with an error (each would post an io ereport), slower than
#   zio_slow_io_ms ($2, in ns; each would post a delay ereport), or neither;
# - its logical reads that fail after it does (each would post a data
#   ereport);
# - the blocks it poisons, by bookmark.
# The checksum ereports that zio_done() finishes don't go through
# zfs_ereport_post(), but no read here gets as far as a checksum error.
#
cat > $D <<'EOF'
#pragma D option quiet

BEGIN
{
	printf("ready\n");
}

fbt::zfs_ereport_post:entry
/stringof(args[1]->spa_name) == $$1/
{
	@ereport[args[1]->spa_exit == 2 ? "after" : "before",
	    stringof(args[0])] = count();
}

fbt::zfs_ereport_post_checksum:entry
/stringof(args[0]->spa_name) == $$1/
{
	@ereport[args[0]->spa_exit == 2 ? "after" : "before",
	    "checksum"] = count();
}

fbt::zio_done:entry
/args[0]->io_vd != NULL && args[0]->io_vd->vdev_ops->vdev_op_leaf &&
    stringof(args[0]->io_spa->spa_name) == $$1/
{
	@leaf[args[0]->io_spa->spa_exit == 2 ? "after" : "before",
	    args[0]->io_error != 0 ? "error" :
	    args[0]->io_delay >= $2 ? "slow" : "ok",
	    args[0]->io_type == 1 ? "read" :
	    args[0]->io_type == 2 ? "write" : "other"] = count();
}

fbt::zio_done:entry
/args[0]->io_logical == args[0] && args[0]->io_type == 1 &&
    args[0]->io_error != 0 && args[0]->io_spa->spa_exit == 2 &&
    stringof(args[0]->io_spa->spa_name) == $$1/
{
	@logical["after", "read", "error"] = count();
}

sdt:::spa-exit-poisoned-read
/stringof(((spa_t *)arg0)->spa_name) == $$1/
{
	this->zb = (zbookmark_phys_t *)arg1;
	@poisoned[this->zb->zb_objset, this->zb->zb_object,
	    this->zb->zb_level] = count();
}

tick-300s
{
	exit(0);
}

END
{
	printa("ereport %s %s %@d\n", @ereport);
	printa("leaf %s %s %s %@d\n", @leaf);
	printa("logical %s %s %s %@d\n", @logical);
	printa("poisoned %d %d %d %@d\n", @poisoned);
}
EOF
dtrace -s $D $TESTPOOL $((SLOW_MS * 1000000)) > $DOUT 2>&1 &
dpid=$!
tries=40
until grep -q "^ready" $DOUT 2>/dev/null; do
	kill -0 $dpid 2>/dev/null || log_fail "dtrace failed: $(cat $DOUT)"
	((tries-- == 0)) && log_fail "dtrace didn't start"
	sleep 0.5
done

typeset -i p0=$(kstat forced_exit.poisoned_reads)
typeset -i f0=$(failed_ereports io_failure)
typeset -i b0=$(failed_ereports 'io|data|checksum|delay')

log_must zinject -d $FAILMODE_VDEV -D $DELAY_MS:$NREADS $TESTPOOL
typeset -i t0=$SECONDS i
for ((i = 1; i <= NREADS; i++)); do
	dd if=$FILE of=/dev/null bs=128k count=1 iseek=$((4 * i)) \
	    >/dev/null 2>&1 &
	rpids[i]=$!
done
typeset -i n
tries=20
while :; do
	n=$(in_device)
	((n >= NREADS)) && break
	((tries-- == 0)) && log_fail "only $n of $NREADS reads reached the vdev"
	sleep 0.5
done
log_note "$n I/Os in the vdev, $(kstat_pool $TESTPOOL rcnt) of them issued"

zpool export -F $TESTPOOL >/dev/null 2>$EERR &
epid=$!
tries=20
until pool_has_failed $TESTPOOL; do
	((tries-- == 0)) && log_fail "zpool export -F didn't fail the pool"
	sleep 0.5
done
log_note "the pool failed $((int(SECONDS) - t0))s after the reads started"
# Injection handlers hold the pool, and the export waits for them to go.
log_must zinject -c all

tries=90
while kill -0 $epid 2>/dev/null; do
	((tries-- == 0)) && log_fail "zpool export -F didn't finish"
	sleep 1
done
wait $epid
typeset -i rc=$?
epid=""
log_note "zpool export -F returned $rc: $(cat $EERR)"
log_must test $rc -eq 0
log_mustnot poolexists $TESTPOOL

typeset -i ok=0 failed=0 pid
tries=60
for pid in ${rpids[@]}; do
	while kill -0 $pid 2>/dev/null; do
		((tries-- == 0)) && log_fail "a reader didn't finish"
		sleep 1
	done
done
for pid in ${rpids[@]}; do
	if wait $pid; then
		((ok++))
	else
		((failed++))
	fi
done
# Not "rpids=()": ksh93 would make it a compound variable, "( )".
unset rpids
log_note "readers: $ok read their block, $failed failed"

# A background job ignores SIGINT, so stop dtrace with SIGTERM.
kill -TERM $dpid
wait $dpid
dpid=""
log_note "$(grep -v '^ready' $DOUT)"

#
# What the pool did: no I/O failed or came back late before it failed, so
# nothing could have been reported then, or have raced with the failure.
# After it, every queued read went into the fence: its block was poisoned,
# its leaf and logical zios failed, and its reader got an error rather than
# zeros.  The reads held in the device came back late.
#
typeset -i poisoned=$(($(kstat forced_exit.poisoned_reads) - p0))
typeset -i dropped=$(dcount poisoned $objset $obj 0)
typeset -i early=$(($(dcount leaf before error) + $(dcount leaf before slow)))
typeset -i leaf_err=$(dcount leaf after error read)
typeset -i data_err=$(dcount logical after read error)
typeset -i late=$(dcount leaf after slow read)
log_note "$dropped of the file's blocks poisoned ($poisoned in all);" \
    "failed after the failure: $leaf_err leaf reads, $data_err logical" \
    "reads; $late held reads came back late"
((early == 0)) || log_fail "$early I/Os failed or came back late before" \
    "the pool failed, which must happen while the reads are held"
((dropped >= NQUEUED / 2)) ||
    log_fail "only $dropped of the $NQUEUED queued reads were poisoned"
((poisoned >= dropped)) ||
    log_fail "poisoned_reads rose by $poisoned, not $dropped"
((leaf_err >= dropped)) ||
    log_fail "only $leaf_err leaf reads failed, for $dropped poisoned blocks"
((data_err >= dropped)) ||
    log_fail "only $data_err logical reads failed, for $dropped poisoned" \
    "blocks"
((late >= 1)) ||
    log_fail "no held read came back slower than zio_slow_io_ms"
((failed >= dropped)) ||
    log_fail "$((dropped - failed)) readers of poisoned blocks got no error"

# All the pool posted was its io_failure, after it failed.
typeset -i io_failure=$(dcount ereport after io_failure)
typeset -i posted=$(dcount ereport)
((io_failure == 1)) ||
    log_fail "the pool posted $io_failure io_failure ereports, not 1"
((posted == 1)) || log_fail "the pool posted more ereports than its" \
    "io_failure: $(grep '^ereport ' $DOUT | tr '\n' ' ')"

#
# And so fmd logged its io_failure (which shows that this pool's ereports
# reach the log, and match the filter), and nothing for its I/O.
#
tries=30
until (($(failed_ereports io_failure) > f0)); do
	((tries-- == 0)) && log_fail "fmd didn't log the pool's io_failure"
	sleep 1
done
# Give fmd time for anything posted after the io_failure.
sleep 5
typeset -i bad=$(($(failed_ereports 'io|data|checksum|delay') - b0))
((bad <= 0)) || log_fail "fmd logged $bad io, data, checksum or delay" \
    "ereports from the failed pool"

log_pass "A failed pool posts one io_failure ereport, and none for each" \
    "of its I/Os"
