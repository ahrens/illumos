#!/bin/ksh
#
# chaos.sh <iterations>: fail a pool at a random moment while a mixed
# workload runs, over and over (v4).
#
# Each iteration draws, from a seed it logs, how the pool is built and how it
# fails (override any choice with CHAOS_FORCE="key=value,..."):
#   shape     file3: 3 file vdevs striped; lofi1/lofi3: 1 or 3 lofi devices
#             (vdev_disk, ashift=12, like an Oxide U.2 pool)
#   failmode  death, or wait/continue (the pool suspends first)
#   trigger   wfail: every write fails before it reaches the disk
#             (zinject -e io-prefail -T write), labels too
#             afail: every read and write fails that way, labels too
#             vanish: the lofi devices go away (lofiadm -f -d)
#             F: "zpool export -F" of the busy pool, with no I/O error
#   resolve   (wait/continue) after a 0-3 s dwell suspended: F (export -F).
#             "zpool set failmode=death" can't resolve it: zpool set on a
#             suspended pool gets EAGAIN (review L13).
#   export    -f, plain or -F, with a concurrent duplicate 1 time in 5
#
# Workload: fsync and O_DSYNC file writers, one of them in an encrypted
# (aes-256-gcm, raw key) hierarchy like Oxide's crypt dataset, and an
# O_DSYNC raw-zvol writer (volblocksize 128k, so its log records use
# dmu_sync()), all logging what was acknowledged; a send to a healthy pool
# and a resumable receive from it; snapshots created and destroyed; a scrub;
# and the zpool/zfs commands sled-agent polls, timed.  Holders keep the pool
# busy through the export: the writers keep their descriptors open after
# their first error, a process maps a file and dirties it, a binary runs
# from the pool, and a process sits in a snapshot directory while another
# reads it.  Activity modules (acts/act_*.sh), each in half the iterations,
# add a Crucible-like region with long-lived snapshots, an async destroy, a
# rename/directory-fsync churn, online receives, key rotation, and holders
# that are torn down one by one while the pool is failed; each checks its
# own durability rules after the import.
#
# Each iteration checks:
# - the pool fails; DTrace records what was running and spa_ubsync;
# - no I/O reaches a leaf vdev once the pool has failed (the fence);
# - every writer gets an error within 20 s, and no write that started after
#   the failure is acknowledged;
# - the export succeeds within 60 s with the holders still attached, prints
#   no unmount warning, cancels the streams, and leaves nothing mounted;
# - the holders die promptly when killed, and the zvol's minor goes away;
# - no polled command took more than 30 s, unless a pool command wedged
#   (blocked 30 s): then "zpool export -F" must release it, and only a
#   wait/continue pool may wedge (result "wedge"; review L16);
# - the on-disk uberblock is spa_ubsync's txg or the next one;
# - no two log blocks to claim share a DVA;
# - the pool imports, every acknowledged file and zvol write is there (the
#   zvol's log replayed), a scrub is clean, and zdb -bcc is clean.
# Results go to $DIR/chaos.log and one line per iteration to $DIR/chaos.csv.
#
POOL=${CHAOS_POOL:-chaospool}; OK=${POOL%pool}ok
H=${CHAOS_HELPERS:-/var/tmp/chaos-helpers4}
DIR=${CHAOS_DIR:-/var/tmp/chaos}
VD=$DIR/vdev; OKV=$DIR/ok/v
LOG=$DIR/chaos.log; CSV=$DIR/chaos.csv
ZV=/dev/zvol/rdsk/$POOL/vol
ZVSLOTS=2048
POLL_MAX_MS=30000
WEDGE_S=${CHAOS_WEDGE_S:-30}
N=${1:-50}
RUNSEED=${CHAOS_SEED:-$(($(date +%s) % 100000))}
typeset -a streams holders devs
typeset mmap_pid="" poll_pid="" wedge_pid="" scan=""

note() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }
# Append with +=, and empty with unset: after "a=()", ksh93 counts one element,
# so "a[${#a[@]}]=x" kept overwriting a[1] and tracked only the last one.
stream() { "$@" & streams+=($!); }
holder() { "$@" & holders+=($!); }

# Activity modules: $H/acts/act_NAME.sh defines act_NAME_setup, _start and
# _verify (see the review that added them).  Each runs in an iteration with
# probability 1/2, or as CHAOS_FORCE says (act_NAME=0|1); CHAOS_ACTS limits
# the set.
typeset -a ALL_ACTS acts
for af in $H/acts/act_*.sh; do
	[[ -f $af ]] || continue
	af=${af##*/act_}; af=${af%.sh}
	[[ -n $CHAOS_ACTS && ",$CHAOS_ACTS," != *",$af,"* ]] && continue
	. $H/acts/act_$af.sh
	ALL_ACTS+=($af)
done

# Clear only this pool's zinject handlers, so that runs can share a host.
zinject_clear()
{
	typeset id
	for id in $(zinject 2>/dev/null | nawk -v p=$POOL '$2 == p && $1 ~ /^[0-9]+$/ { print $1 }'); do
		zinject -c $id >/dev/null 2>&1
	done
}

# pick <key> "<value>:<weight> ...": a CHAOS_FORCE value, or a weighted draw
pick()
{
	typeset key=$1 spec=$2 kv v w
	typeset -i total=0 r
	for kv in ${CHAOS_FORCE//,/ }; do
		[[ ${kv%%=*} == $key ]] && { print -r -- "${kv#*=}"; return; }
	done
	for kv in $spec; do total=$((total + ${kv#*:})); done
	r=$((RANDOM % total))
	for kv in $spec; do
		v=${kv%:*}; w=${kv#*:}
		((r < w)) && { print -r -- "$v"; return; }
		r=$((r - w))
	done
}

pool_state() # "<spa_exit> <spa_suspended>"; exit 2 = failed
{
	typeset fmt='::printf "%s %d %d\n" spa_t spa_name spa_exit spa_suspended'
	print -r -- "::walk spa | $fmt" | mdb -k | nawk -v p=$POOL '$1 == p { print $2, $3 }'
}

pool_mounts()
{
	mount -p | nawk -v p=$POOL '$4 == "zfs" && ($1 == p ||
	    index($1, p "/") == 1 || index($1, p "@") == 1) { print $3 }'
}

alive() # pids...: print those still running
{
	typeset p
	for p in "$@"; do
		kill -0 $p 2>/dev/null && print -n "$p "
	done
}

# wait_gone <seconds> <pids...>: 0 once all have exited
wait_gone()
{
	typeset -i t=$(($1 * 2)); shift
	while [[ -n $(alive "$@") ]]; do
		((t-- == 0)) && return 1
		sleep 0.5
	done
	return 0
}

# wait_state <seconds> <failed|suspended>
wait_state()
{
	typeset -i t=$(($1 * 2))
	typeset s
	while :; do
		s=$(pool_state)
		[[ $2 == failed && ${s% *} == 2 ]] && return 0
		[[ $2 == suspended && -n $s && ${s#* } != 0 ]] && return 0
		((t-- == 0)) && return 1
		sleep 0.5
	done
}

# wedge_watch, from the trigger to the export: a pool command that blocks for
# $WEDGE_S seconds means that a thread sleeps on the failing pool holding
# spa_namespace_lock (review L16: the async thread's SCL_ALL write lock is
# queued behind a suspended sync, so "zpool list" waits to read the config).
# Save the stacks, then fail the pool with "zpool export -F", which has to
# release every such sleeper.  It probes the bystander pool, which the
# failure leaves alone.
wedge_watch()
{
	typeset -i t
	typeset p
	while :; do
		zpool list -H -o name $OK >/dev/null 2>&1 &
		p=$!
		t=$((WEDGE_S * 2))
		while kill -0 $p 2>/dev/null; do
			if ((t-- == 0)); then
				print "wedged $(date -u +%T)" > $DIR/wedge
				echo "::stacks -m zfs" | mdb -k > $DIR/wedge.stacks 2>&1
				zpool export -F $POOL > $DIR/wedge.export 2>&1
				print "rc $?" >> $DIR/wedge.export
				wait $p
				print "released $(date -u +%T)" >> $DIR/wedge
				return
			fi
			sleep 0.5
		done
		sleep 1
	done
}

# wedge_stop: stop the watcher, or, if it found a wedge, give its export -F
# 90 s to release it; 0 unless the wedge outlived the export -F
wedge_stop()
{
	[[ -n $wedge_pid ]] || return 0
	if [[ -f $DIR/wedge ]]; then
		wait_gone 90 $wedge_pid || return 1
	else
		pkill -9 -P $wedge_pid >/dev/null 2>&1
		kill -9 $wedge_pid >/dev/null 2>&1
		wait $wedge_pid 2>/dev/null
	fi
	wedge_pid=""
	return 0
}

# destroy_busy <pool>: zpool destroy, retrying for 10 s while it is busy.  A
# pool just imported can be held for a moment (fmd and sysevent handlers
# open it; ZTS's log_must_busy retries for the same reason).  Save the ZFS
# stacks at the first EBUSY, so that a hold that never drains shows its owner.
destroy_busy()
{
	typeset -i dbn
	for ((dbn = 0; dbn < 10; dbn++)); do
		zpool destroy $1 2>> $DIR/destroy.err && return 0
		if [[ ! -s $DIR/destroy-busy.stacks ]]; then
			echo "::stacks -m zfs" | mdb -k > $DIR/destroy-busy.stacks 2>&1
			ps -eo pid,args >> $DIR/destroy-busy.stacks 2>&1
		fi
		sleep 1
	done
	return 1
}

killall_bg()
{
	typeset p
	for p in ${streams[@]} ${holders[@]} $mmap_pid $poll_pid $wedge_pid; do
		pkill -9 -P $p >/dev/null 2>&1
		kill -9 $p >/dev/null 2>&1
	done
	pkill -9 -f "[t]hrottle.py" >/dev/null 2>&1
	unset streams holders; typeset -a streams holders
	mmap_pid=""; poll_pid=""; wedge_pid=""
}

lofi_detach() # detach every lofi device backed by our vdev files
{
	typeset f d
	for f in $VD/v1 $VD/v2 $VD/v3; do
		d=$(lofiadm $f 2>/dev/null) && lofiadm -f -d $d >/dev/null 2>&1
	done
}

# evidence <name>: save what explains a failure into $DIR/fail.$it
evidence()
{
	typeset e=$DIR/fail.$it
	mkdir -p $e
	cp $DIR/d.out $DIR/w?.log $DIR/zv.log $DIR/poll.log $DIR/export*.err $e/ 2>/dev/null
	cp $DIR/zil*.out $DIR/zdb.out $e/ 2>/dev/null
	cp $DIR/act_* $e/ 2>/dev/null
	cp $DIR/wedge $DIR/wedge.stacks $DIR/wedge.export $e/ 2>/dev/null
	cp $DIR/destroy.err $DIR/destroy-busy.stacks $DIR/dtrace-late $e/ 2>/dev/null
	echo "::stacks -m zfs" | mdb -k > $e/stacks.zfs 2>&1
	echo "::stacks" | mdb -k > $e/stacks.all 2>&1
	ps -eo pid,ppid,s,wchan,args > $e/ps 2>&1
	note "iter $it: $1 (evidence in $e; seed $seed, $choices)"
}

csv()
{
	print "$it,$seed,$shape,$failmode,$trigger,$resolve,$xport,$ms,$phase,$ub,$ubsync,$el,$fence,$pollmax,$acked,$left,$stuck,${actlist:--},$1" >> $CSV
}

fail() # <result> <message>: record a failure and stop the loop
{
	evidence "$2"; csv $1; fails=fails+1
}

mkdir -p $DIR
for f in writer.py verify.py throttle.py mmap_hold.py overlap.py reuse.py \
    poller.py chaos.d.tmpl; do
	[[ -f $H/$f ]] || { echo "missing $H/$f"; exit 1; }
done
zinject -h 2>&1 | grep -q io-prefail ||
    { echo "zinject has no io-prefail on this build"; exit 1; }
sed "s/POOL/$POOL/" $H/chaos.d.tmpl > $DIR/chaos.d
[[ -f $CSV ]] || print "iter,seed,shape,failmode,trigger,resolve,export,ms,phase,ub,ubsync,export_s,fence,poll_max_ms,acked,zfs_threads,suspect,acts,result" > $CSV

setup()
{
	typeset -i i t
	typeset f opts=""
	lofi_detach
	rm -rf $VD $DIR/ok; mkdir -p $VD $DIR/ok
	mkfile 1g $VD/v1 $VD/v2 $VD/v3 $OKV
	unset devs; typeset -a devs
	case $shape in
	file3)	devs=($VD/v1 $VD/v2 $VD/v3) ;;
	lofi1)	devs=($(lofiadm -a $VD/v1)) ;;
	lofi3)	for f in $VD/v1 $VD/v2 $VD/v3; do
			devs+=($(lofiadm -a $f))
		done ;;
	esac
	[[ $shape == lofi* ]] && opts="-o ashift=12"
	[[ -d /$POOL ]] && find /$POOL -depth -type d -exec rmdir {} \; 2>/dev/null
	zpool create -f $opts -o failmode=$failmode $POOL ${devs[@]} || return 1
	zpool create -f $OK $OKV || return 1
	zfs create -o recordsize=128k $POOL/fs
	zfs create -o compression=off $POOL/data
	for ((i = 0; i < 4; i++)); do
		dd if=/dev/urandom of=/$POOL/data/f$i bs=1024k count=32 2>/dev/null
	done
	zfs snapshot $POOL/data@s
	dd if=/dev/urandom of=$DIR/key bs=32 count=1 2>/dev/null
	zfs create -o encryption=aes-256-gcm -o keyformat=raw \
	    -o keylocation=file://$DIR/key $POOL/crypt || return 1
	zfs create -o recordsize=128k $POOL/crypt/zone
	zfs create -o compression=off $OK/src
	for ((i = 0; i < 4; i++)); do
		dd if=/dev/urandom of=/$OK/src/f$i bs=1024k count=32 2>/dev/null
	done
	zfs snapshot $OK/src@s
	zfs create -o volblocksize=128k -V 256m $POOL/vol || return 1
	mkfile 8m /$POOL/fs/hold
	cp /usr/bin/sleep /$POOL/fs/vsleep
	zpool sync $POOL
	t=20
	until [[ -c $ZV ]]; do
		((t-- == 0)) && { echo "no $ZV"; return 1; }
		sleep 0.5
	done
	return 0
}

workload()
{
	holder python3 $H/writer.py /$POOL/fs/w0 $DIR/w0.log fsync
	holder python3 $H/writer.py /$POOL/fs/w1 $DIR/w1.log dsync
	holder python3 $H/writer.py /$POOL/crypt/zone/w2 $DIR/w2.log dsync
	holder python3 $H/writer.py $ZV $DIR/zv.log zvol $ZVSLOTS
	python3 $H/mmap_hold.py /$POOL/fs/hold 8388608 > $DIR/mmap.out 2>&1 &
	mmap_pid=$!
	holder /$POOL/fs/vsleep 3600
	holder ksh -c "cd /$POOL/data/.zfs/snapshot/s && exec sleep 3600"
	holder ksh -c "while :; do dd if=/$POOL/data/.zfs/snapshot/s/f0 of=/dev/null bs=1024k count=1 2>/dev/null; sleep 0.05; done"
	stream ksh -c "zfs send $POOL/data@s | python3 $H/throttle.py 30 | zfs recv -s -F $OK/fromchaos"
	stream ksh -c "zfs send $OK/src@s | python3 $H/throttle.py 30 | zfs recv -s $POOL/fromok"
	stream ksh -c "i=0; while zfs snapshot $POOL/fs@c\$i && zfs destroy $POOL/fs@c\$i; do i=\$((i+1)); done" >/dev/null 2>&1
	python3 $H/poller.py $DIR/poll.log 1 $POOL $OK &
	poll_pid=$!
	zpool scrub $POOL
}

inject() # <-T type>: fail every I/O of that type before it reaches the disk
{
	typeset d l
	for d in ${devs[@]}; do
		zinject -d $d -e io-prefail -T $1 $POOL >/dev/null
	done
	for l in pad2 uber nvlist; do
		for d in ${devs[@]}; do
			zinject -d $d -L $l $POOL >/dev/null
		done
	done
}

# writers_errored: 0 once every writer log ends in "err" or "full"
writers_errored()
{
	typeset w
	for w in w0 w1 w2 zv; do
		egrep -q "^(err|full) " $DIR/$w.log 2>/dev/null || return 1
	done
	return 0
}

# export_pool <-f|plain|-F>: export, with a concurrent duplicate 1 time in 5;
# sets rc and el
export_pool()
{
	typeset flag=$1 dpid2=""
	[[ $flag == plain ]] && flag=""
	# Functions share variables; a float "s" broke wait_state().
	typeset -F xstart=$SECONDS
	if [[ $dup == 1 ]]; then
		zpool export $flag $POOL > $DIR/export2.err 2>&1 &
		dpid2=$!
	fi
	zpool export $flag $POOL > $DIR/export.err 2>&1
	rc=$?
	if [[ -n $dpid2 ]]; then
		wait $dpid2
		typeset rc2=$?
		# One of the two exports the pool; the other finds it gone.
		if ((rc != 0 && rc2 == 0)); then
			rc=0; mv $DIR/export2.err $DIR/export.err
		fi
	fi
	el=$(printf %.1f $((SECONDS - xstart)))
}

guard()
{
	typeset -i avail=$(df -k /var/tmp | nawk 'NR == 2 { print $4 }')
	if ((avail < 3 * 1024 * 1024)); then
		note "stopping: only $((avail / 1024)) MB free in /var/tmp"
		return 1
	fi
	typeset -i errlog=$(ls -l /var/fm/fmd/errlog 2>/dev/null | nawk '{ print $5 }')
	if ((errlog > 200 * 1024 * 1024)); then
		fmadm rotate errlog >/dev/null 2>&1
		rm -f /var/fm/fmd/errlog.*
		note "rotated fmd's errlog (was $((errlog / 1048576)) MB)"
	fi
	return 0
}

typeset -i it fails=0
note "start: $N iterations (v5, acts ${ALL_ACTS[*]:-none}, run seed $RUNSEED${CHAOS_FORCE:+, forced $CHAOS_FORCE})"
for ((it = 1; it <= N; it++)); do
	seed=$((RUNSEED * 1000 + it)); RANDOM=$seed
	shape=$(pick shape "file3:50 lofi1:25 lofi3:25")
	failmode=$(pick failmode "death:70 wait:15 continue:15")
	if [[ $shape == lofi* ]]; then
		trigger=$(pick trigger "wfail:40 afail:15 F:20 vanish:25")
	else
		trigger=$(pick trigger "wfail:55 afail:20 F:25")
	fi
	resolve="-"
	[[ $failmode != death && $trigger != F ]] && resolve=$(pick resolve "F:100")
	xport=$(pick export "-f:50 plain:25 -F:25")
	[[ $trigger == F || $resolve == F ]] && xport=-F
	dup=$(pick dup "0:80 1:20")
	unset acts; typeset -a acts
	for af in ${ALL_ACTS[@]}; do
		[[ $(pick act_$af "0:50 1:50") == 1 ]] && acts+=($af)
	done
	actlist=$(IFS=+; print -r -- "${acts[*]}")
	choices="shape=$shape failmode=$failmode trigger=$trigger resolve=$resolve export=$xport dup=$dup acts=${actlist:--}"
	ms=""; phase=""; ub=""; ubsync=""; el=""; fence=""; acked=""; left=""
	stuck=""; pollmax=""; rc=0; wedged=0
	guard || break
	if [[ -f $DIR/STOP ]]; then
		rm -f $DIR/STOP; note "stopping: $DIR/STOP"; break
	fi
	if ! setup >> $LOG 2>&1; then
		note "iter $it: SETUP FAILED ($choices)"; fails=fails+1; break
	fi
	rm -f $DIR/w?.log $DIR/zv.log $DIR/poll.log $DIR/export*.err $DIR/dtrace-late
	# The activities' files, not their directories (mount points).
	for af in $DIR/act_*; do [[ -f $af ]] && rm -f $af; done
	asetup=""
	for af in ${acts[@]}; do
		act_${af}_setup >> $LOG 2>&1 || { asetup=$af; break; }
	done
	if [[ -n $asetup ]]; then
		note "iter $it: SETUP FAILED in activity $asetup ($choices)"
		fails=fails+1; break
	fi
	# Empty d.out here, not in the background child: a "ready" left from
	# the last iteration, read before the child truncated the file, ended
	# the wait at once and then failed it (iters 274, 221, 211).
	: > $DIR/d.out
	dtrace -s $DIR/chaos.d >> $DIR/d.out 2>&1 &
	dpid=$!
	typeset -F dt0=$SECONDS
	typeset -i polls=0
	until grep -q ready $DIR/d.out 2>/dev/null; do
		((SECONDS - dt0 > 120)) && break
		polls=polls+1
		sleep 0.5
	done
	if ! grep -q ready $DIR/d.out; then
		printf "not ready after %.1f s, %d polls\n" $((SECONDS - dt0)) \
		    $polls > $DIR/dtrace-late
		pstack $dpid >> $DIR/dtrace-late 2>&1
		echo "0t$dpid::pid2proc | ::walk thread | ::findstack -v" |
		    mdb -k >> $DIR/dtrace-late 2>&1
		kill $dpid 2>/dev/null
		fail dtrace "DTRACE DID NOT START IN 120 s"; break
	fi
	workload >> $DIR/workload.out 2>&1
	for af in ${acts[@]}; do
		act_${af}_start
	done >> $DIR/workload.out 2>&1 < /dev/null
	ms=$((RANDOM % 5000))
	sleep $((ms / 1000.0))

	exported=0
	rm -f $DIR/wedge $DIR/wedge.stacks $DIR/wedge.export
	if [[ $trigger != F ]]; then
		wedge_watch &
		wedge_pid=$!
	fi
	case $trigger in
	wfail)	inject write ;;
	afail)	inject all ;;
	vanish)	for d in ${devs[@]}; do lofiadm -f -d $d >> $LOG 2>&1 || note "lofiadm -f -d $d failed"; done ;;
	F)	export_pool -F; exported=1 ;;
	esac
	if ((exported == 0)) && [[ $failmode != death ]]; then
		typeset -i dwell=$((RANDOM % 3000))
		if ! wait_state 60 suspended && [[ ! -f $DIR/wedge ]]; then
			fail nosuspend "POOL DID NOT SUSPEND (after $ms ms)"; break
		fi
		[[ -f $DIR/wedge ]] || sleep $((dwell / 1000.0))
		if ! wedge_stop; then
			fail wedge "WEDGE NOT RELEASED BY zpool export -F"; break
		fi
		# zinject handlers keep any export waiting.
		zinject_clear
		# The watcher's export -F may have exported the pool already.
		if [[ -f $DIR/wedge ]] && ! zpool list $POOL >/dev/null 2>&1; then
			rc=0; el=0
		else
			export_pool -F
		fi
		exported=1
	fi
	if ((exported == 0)) && ! wait_state 60 failed; then
		fail nofail "POOL DID NOT FAIL (after $ms ms)"; break
	fi

	# Every active writer gets an error; the holders keep their fds.
	t=40
	until writers_errored; do
		((t-- == 0)) && break
		sleep 0.5
	done
	if ! writers_errored; then
		fail noerr "A WRITER GOT NO ERROR within 20 s"; break
	fi
	if [[ $((it % 2)) == 1 ]]; then
		kill -9 $mmap_pid 2>/dev/null; wait $mmap_pid 2>/dev/null
	fi

	# Export with everything still attached.
	if ! wedge_stop; then
		fail wedge "WEDGE NOT RELEASED BY zpool export -F"; break
	fi
	if [[ -f $DIR/wedge ]]; then
		wedged=1
		mkdir -p $DIR/wedge.$it
		mv $DIR/wedge $DIR/wedge.stacks $DIR/wedge.export $DIR/wedge.$it/
		typeset wl="$(cat $DIR/wedge.$it/wedge $DIR/wedge.$it/wedge.export | tr '\n' ' ')"
		# A death pool fails by itself, so nothing should sleep on it.
		if [[ $failmode == death ]]; then
			fail wedge "A DEATH POOL WEDGED POOL COMMANDS: $wl"; break
		fi
		note "iter $it: WEDGE released by zpool export -F: $wl(stacks in wedge.$it)"
	fi
	zinject_clear
	if ((exported == 0)); then
		if ((wedged)) && ! zpool list $POOL >/dev/null 2>&1; then
			rc=0; el=0
		else
			export_pool $xport
		fi
	fi
	if ((rc != 0)) || [[ ${el%.*} -gt 60 ]]; then
		fail export "EXPORT $xport rc $rc after $el s"; break
	fi
	if [[ -s $DIR/export.err ]]; then
		fail exportwarn "EXPORT $xport WARNED: $(head -1 $DIR/export.err)"; break
	fi
	if ! wait_gone 15 ${streams[@]}; then
		fail streams "STREAMS NOT CANCELLED BY THE EXPORT: $(alive ${streams[@]})"
		break
	fi
	typeset m=$(pool_mounts)
	if [[ -n $m ]]; then
		fail mounted "LEFT MOUNTED AFTER EXPORT: $m"; break
	fi
	kill -9 ${holders[@]} $mmap_pid 2>/dev/null
	if ! wait_gone 10 ${holders[@]} $mmap_pid; then
		fail holders "HOLDERS DID NOT DIE: $(alive ${holders[@]} $mmap_pid)"
		break
	fi
	t=10
	while [[ -e $ZV ]]; do
		((t-- == 0)) && break
		sleep 0.5
	done
	if [[ -e $ZV ]]; then
		fail minor "ZVOL MINOR LEFT AFTER LAST CLOSE"; break
	fi
	kill -9 $poll_pid 2>/dev/null; wait $poll_pid 2>/dev/null
	pollmax=$(nawk 'BEGIN { m = 0 } $2 > m { m = $2 } END { print m }' $DIR/poll.log)
	killall_bg
	# A wedge holds the polled commands until the export -F releases it.
	if ((pollmax > POLL_MAX_MS && wedged == 0)); then
		fail poll "A POLLED COMMAND TOOK $pollmax ms: $(nawk -v m=$pollmax '$2 == m' $DIR/poll.log | head -1)"
		break
	fi

	sleep 1
	kill -TERM $dpid >/dev/null 2>&1; wait $dpid 2>/dev/null
	typeset fail_ns=$(nawk '$1 == "spa_fail" { print $2; exit }' $DIR/d.out)
	ubsync=$(nawk '$1 == "UBSYNC" { print $2; exit }' $DIR/d.out)
	typeset b=$(grep BUCKETS $DIR/d.out | sed 's/^BUCKETS //')
	if [[ -z $b || -z $fail_ns ]]; then
		b="phase=NOTRACE"
		mkdir -p $DIR/notrace.$it; cp $DIR/d.out $DIR/notrace.$it/
	fi
	print -r -- "$b $choices" >> $DIR/buckets
	phase=$(print -r -- "$b" | nawk '{ sub("phase=", "", $1); print $1 }')
	fence=$(grep -c "^FENCE " $DIR/d.out)
	if ((fence != 0)); then
		fail fence "FENCE: $fence leaf I/Os started after the failure"; break
	fi
	grep drops $DIR/d.out | head -1 >> $LOG
	if [[ -n $fail_ns ]] && ! python3 $H/verify.py afterfail $fail_ns \
	    $DIR/w0.log $DIR/w1.log $DIR/w2.log $DIR/zv.log >> $LOG 2>&1; then
		fail afterfail "A WRITE STARTED AFTER THE FAILURE WAS ACKNOWLEDGED"
		break
	fi
	if ! python3 $H/overlap.py $DIR/d.out > $DIR/overlap.out 2>&1; then
		mkdir -p $DIR/overlap.$it
		cp $DIR/d.out $DIR/overlap.out $DIR/overlap.$it/
		note "iter $it: ALLOCATION OVERLAP: $(head -1 $DIR/overlap.out)"
	fi
	if ! python3 $H/reuse.py $DIR/d.out > $DIR/reuse.out 2>&1; then
		mkdir -p $DIR/reuse.$it
		cp $DIR/d.out $DIR/reuse.out $DIR/reuse.$it/
		note "iter $it: OPEN-CONTEXT REUSE: $(head -1 $DIR/reuse.out)"
	fi

	sleep 1
	left=$(echo "::stacks -m zfs" | mdb -k | grep -c "^[0-9a-f]")
	stuck=$(echo "::stacks -m zfs" | mdb -k | egrep -c "spa_exit|zil_commit|dmu_send|dmu_recv|zvol_|txg_wait")
	if ((stuck != 0)); then
		mkdir -p $DIR/stuck.$it
		echo "::stacks -m zfs" | mdb -k > $DIR/stuck.$it/stacks 2>&1
	fi

	# A lofi pool's labels say "disk": look at it through lofi again.
	scan=$VD
	if [[ $shape == lofi* ]]; then
		lofi_detach
		case $shape in
		lofi1)	lofiadm -a $VD/v1 >/dev/null ;;
		lofi3)	for f in $VD/v1 $VD/v2 $VD/v3; do lofiadm -a $f >/dev/null; done ;;
		esac
		scan=/dev/lofi
	fi
	# The disks hold spa_ubsync's txg, or the next one if the pool failed
	# after that txg's uberblocks landed but before its labels did.
	ub=$(zdb -e -p $scan -u $POOL 2>/dev/null | nawk '$1 == "txg" { print $3; exit }')
	if [[ -n $ubsync ]] && ((ub != ubsync && ub != ubsync + 1)); then
		fail ub "ON-DISK TXG $ub, BUT spa_ubsync WAS $ubsync"; break
	fi
	# Two blocks the import would claim must not share a DVA (the ARC
	# keys blocks by DVA and birth, so zil_claim() panics on them).
	rm -f $DIR/zil3-*.out
	for d in fs vol crypt/zone crucible/r0 crypt/nschurn; do
		zdb -e -p $scan -iiivvvv $POOL/$d > $DIR/zil3-${d##*/}.out 2>&1
	done
	typeset dupdva=$(cat $DIR/zil3-*.out | nawk -v ub=$ub '
	    /DVA\[0\]=</ {
		if (match($0, /DVA\[0\]=<[0-9]+:[0-9a-f]+:/) == 0) next
		k = substr($0, RSTART + 8, RLENGTH - 9)
		if (match($0, /birth=[0-9]+L/) == 0) next
		b = substr($0, RSTART + 6, RLENGTH - 7) + 0
		if (b > ub && n[k]++) print k
	    }' | head -3)
	if [[ -n $dupdva ]]; then
		fail dupdva "DUPLICATE DVA in the logs to claim (ub $ub): $dupdva"; break
	fi
	if ! zpool import -N -d $scan $POOL >> $LOG 2>&1; then
		fail import "IMPORT FAILED"; break
	fi
	# The log as the import found it, before the mount replays it.
	zdb -ivv $POOL/fs > $DIR/zil.out 2>&1
	zfs load-key -r $POOL/crypt >> $LOG 2>&1
	zfs mount -a >> $LOG 2>&1
	t=20
	until [[ -c $ZV ]]; do
		((t-- == 0)) && break
		sleep 0.5
	done
	bad=0
	python3 $H/verify.py durable /$POOL/fs/w0 $DIR/w0.log >> $LOG 2>&1 || bad=1
	python3 $H/verify.py durable /$POOL/fs/w1 $DIR/w1.log >> $LOG 2>&1 || bad=1
	python3 $H/verify.py durable /$POOL/crypt/zone/w2 $DIR/w2.log >> $LOG 2>&1 || bad=1
	python3 $H/verify.py durable $ZV $DIR/zv.log >> $LOG 2>&1 || bad=1
	acked=$(for w in w0 w1 w2 zv; do egrep -c "^[0-9]+ " $DIR/$w.log; done | paste -s -d/ -)
	if ((bad)); then
		fail lost "ACKNOWLEDGED WRITES LOST"; break
	fi
	abad=""
	for af in ${acts[@]}; do
		aout=$(act_${af}_verify 2>> $LOG)
		arc=$?
		print -r -- "$aout" | while read -r aline; do note "  $af: $aline"; done
		((arc != 0)) && { abad="$af: $(print -r -- "$aout" | head -1)"; break; }
	done
	if [[ -n $abad ]]; then
		fail act "ACTIVITY FAILED: $abad"; break
	fi
	zpool scrub -w $POOL
	if ! zpool status -v $POOL | grep -q "No known data errors"; then
		zpool status -v $POOL >> $LOG; fail scrub "SCRUB ERRORS"; break
	fi
	if ! zpool export $POOL; then
		fail export2 "plain export failed"; break
	fi
	zdb -e -p $scan -bcc $POOL > $DIR/zdb.out 2>&1
	typeset zrc=$?
	if ((zrc != 0)) || egrep -qi "\(leaked|leaked:|refcount mismatch|checksum mismatch|error [0-9]|zdb_blkptr_cb" $DIR/zdb.out || ! grep -q "No leaks" $DIR/zdb.out; then
		cp $DIR/zdb.out $DIR/zdb.fail.$it
		fail zdb "ZDB rc $zrc (see zdb.fail.$it)"; break
	fi
	rm -f $DIR/destroy.err $DIR/destroy-busy.stacks
	if ! zpool import -d $scan $POOL 2>> $DIR/destroy.err; then
		fail import2 "IMPORT FOR DESTROY FAILED: $(tail -1 $DIR/destroy.err)"; break
	fi
	if ! destroy_busy $POOL || ! destroy_busy $OK; then
		fail destroy "DESTROY STILL BUSY AFTER 10 s: $(tail -1 $DIR/destroy.err)"
		break
	fi
	if [[ -s $DIR/destroy-busy.stacks ]]; then
		mkdir -p $DIR/destroy-busy.$it
		mv $DIR/destroy.err $DIR/destroy-busy.stacks $DIR/destroy-busy.$it/
		note "iter $it: zpool destroy was busy at first (stacks in destroy-busy.$it)"
	fi
	lofi_detach
	typeset wtag=""
	if ((wedged)); then csv wedge; wtag=" (wedge)"; else csv ok; fi
	note "iter $it ok$wtag: $choices, fail at ${ms} ms, export $el s, ub $ub/$ubsync, acked $acked, poll max $pollmax ms, zfs stacks $left ($stuck suspect), $b"
done
killall_bg
zinject_clear
# Leave nothing suspended behind a failure: fail and export the pool (it can
# still be imported for a post-mortem), and drop the bystander pool.
if zpool list $POOL >/dev/null 2>&1; then
	zpool export -F $POOL >> $LOG 2>&1 || note "cleanup: zpool export -F $POOL failed"
fi
zpool list $OK >/dev/null 2>&1 && zpool destroy -f $OK
lofi_detach
note "done: $((it - 1)) iterations, $fails failures"
echo "counts:" >> $LOG
for k in phase shape failmode trigger resolve export dup send recv zil_commit dmu_sync zvol; do
	nawk -v k=$k '{ for (i = 1; i <= NF; i++) { split($i, a, "="); if (a[1] == k) c[a[2]]++ } }
	    END { printf("  %s:", k); for (v in c) printf(" %s=%d", v, c[v]); printf("\n") }' $DIR/buckets >> $LOG
done
echo "CHAOS DONE" >> $LOG
