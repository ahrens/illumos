#
# act_asyncdestroy.sh: chaos activity "asyncdestroy", sourced by chaos.sh.
#
# An async destroy in flight when the pool fails.
#
# setup builds $POOL/asyncdestroy (recordsize=4k, compression=off,
# canmount=noauto): 1 MB files, 256 4K blocks each behind one L1, 16 at a
# time with a "zpool sync" after each batch, up to 80 files (48 on lofi1),
# stopping before a batch that would likely end past 1.5 s, so that setup
# stays under ~5 s.  So up to 20480 data blocks.  It then snapshots it (@s)
# and overwrites 8 files, so that the snapshot alone owns 2048 more blocks,
# unmounts it (so that destroying it needs no unmount, and its dbufs are
# gone), and records its "referenced".
#
# start destroys @s and then, if that returned 0, the dataset, through
# libzfs_core (lzc_destroy_snaps(), lzc_destroy()) rather than "zfs
# destroy", which reports success when the destroy ioctl fails with ENOENT
# (zfs_destroy()), as it does once the export has removed the pool.  The
# snapshot's own blocks go to the pool's free bpobj and the dataset's to the
# bptree, and dsl_scan_sync() frees both in the background
# (dsl_process_async_destroys(): bpobj_iterate(), then bptree_iterate()).
# To keep that going for a while, most iterations throttle it with
# zfs_async_block_max_blocks (250, 1000 or 4000 blocks per txg; a quarter
# run unthrottled and free everything in the destroy's txg), and half flush
# the ARC (zinject -a) just before the destroys, so that the bptree's L1s
# are read from disk, and poisoned if the pool fails meanwhile.  Each
# destroy's errno and times (time.monotonic_ns(), DTrace's timestamp) go to
# $DIR/act_asyncdestroy.log.
#
# verify, after the import:
# - A destroy that returned 0 committed its txg (dsl_sync_task() returns EIO
#   for a txg that was drained rather than committed), so its snapshot or
#   dataset is gone.  One that failed may or may not have happened (the
#   pool can fail after the txg's uberblocks landed), so nothing is required
#   of it.
# - If the dataset is still there, it references what setup recorded:
#   nothing writes it after setup, and destroying its snapshot doesn't
#   change its referenced bytes.  This relies on its objset block never
#   being rewritten after setup's last "zpool sync": it stays unmounted
#   (canmount=noauto, so "zfs mount -a" skips it), and its ZIL is empty
#   (no sync writes), so zil_claim() at import doesn't dirty it either.
#   A rewritten objset block can change "referenced" by a sector.
# - The frees drain: within 60 s "zpool wait -t free" (free bpobj empty and
#   no async_destroy) has returned and "freeing" is 0; and "leaked" is 0.
#   An I/O error while freeing leaks only with zfs_free_leak_on_eio set (off
#   by default); otherwise bptree_iterate() keeps the entry and tries it
#   again in a later txg, which after the import succeeds.
# The harness's scrub and zdb -bcc then catch blocks that were leaked or
# freed twice.  verify prints one line.
#
# zfs_async_block_max_blocks is global (every pool).  The destroy stream
# sets it back to its default, UINT64_MAX (dsl_scan.c), once nothing of the
# pool is mounted any more (the export) or 10 s after it started; verify
# sets it back if the stream didn't, and so does act_asyncdestroy_cleanup.
# A run that stops between this setup and the stream's restore (a DTrace
# failure, or any failure that breaks out of the loop while the stream is
# still running, since killall_bg then kills it) leaves it throttled: call
# act_asyncdestroy_cleanup when the run ends.  Unthrottled iterations write
# the default too, so a leftover value can't change their variant.  The
# 10 s cap keeps the stream's exit within 13 s of its start (or 3 s of the
# export cancelling a destroy that a suspended pool held up) even if the
# pool's mounts outlive the export, so that the harness reports that as
# LEFT MOUNTED rather than as a stream the export didn't cancel.
#
# The variants come from a hash of $it, not $RANDOM, so that the harness's
# own draws don't shift; CHAOS_FORCE="ad_throttle=N,ad_flush=0|1" overrides
# them (ad_throttle=0: unthrottled).
#
# Files in $DIR: act_asyncdestroy.py (the helper, written by setup),
# .setup (what setup built and drew), .log (the destroy stream's results),
# .err (the helper's and commands' errors), .mdb (every tunable write).
#

function act_asyncdestroy_force	# <key> <default>: CHAOS_FORCE's value, or the default
{
	typeset kv
	for kv in ${CHAOS_FORCE//,/ }; do
		[[ ${kv%%=*} == $1 ]] && { print -r -- "${kv#*=}"; return; }
	done
	print -r -- "$2"
}

function act_asyncdestroy_tune	# <mdb value>: set zfs_async_block_max_blocks
{
	typeset o
	o=$(print "zfs_async_block_max_blocks/Z $1" | mdb -kw 2>&1)
	print -r -- "$(date '+%m-%d %H:%M:%S') iter $it: set $1: ${o//$'\n'/ }" \
	    >> $DIR/act_asyncdestroy.mdb
	# mdb echoes a write as "<symbol>: <old> = <new>", in hex.
	[[ $o == *0x*=*0x* ]]
}

function act_asyncdestroy_cleanup
{
	act_asyncdestroy_tune 0xffffffffffffffff
}

function act_asyncdestroy_setup
{
	typeset f=$DIR/act_asyncdestroy ds=$POOL/asyncdestroy out ref
	typeset -i x maxfiles=80 throttle flush tuned=0 mpid=0 brc
	typeset -F s=$SECONDS

	[[ -n $DIR && -n $POOL ]] || { print "asyncdestroy: DIR or POOL unset"; return 1; }
	rm -f $f.setup $f.log $f.err
	# A 24-bit integer hash of $it.  Every product stays below 2^53, so
	# ksh93's floating-point arithmetic computes it exactly.
	x=$((it & 16777215))
	x=$(( ((x >> 12) ^ x) * 4577779 % 16777216 ))
	x=$(( ((x >> 12) ^ x) * 4577779 % 16777216 ))
	x=$(( (x >> 12) ^ x ))
	flush=$(act_asyncdestroy_force ad_flush $((x & 1)))
	case $(( (x >> 1) & 3 )) in
	0)	throttle=0 ;;
	1)	throttle=250 ;;
	2)	throttle=1000 ;;
	3)	throttle=4000 ;;
	esac
	throttle=$(act_asyncdestroy_force ad_throttle $throttle)
	[[ $shape == lofi1 ]] && maxfiles=48
	act_asyncdestroy_helper > $f.py

	if ! zfs create -o recordsize=4k -o compression=off -o canmount=noauto \
	    $ds > $f.err 2>&1 || ! zfs mount $ds >> $f.err 2>&1; then
		print "asyncdestroy: cannot create and mount $ds: $(tail -1 $f.err)"
		return 1
	fi
	# mdb takes a while to load: let it run while the files are written.
	# Unthrottled iterations write the default, so that a value an
	# earlier run left behind (see act_asyncdestroy_cleanup) can't turn
	# them into throttled ones.
	if ((throttle != 0)); then
		act_asyncdestroy_tune 0t$throttle &
	else
		act_asyncdestroy_tune 0xffffffffffffffff &
	fi
	mpid=$!
	out=$(python3 $f.py build /$POOL/asyncdestroy $ds $POOL $maxfiles 1.5 \
	    2>> $f.err)
	brc=$?
	if wait $mpid; then
		tuned=1
	fi
	if ((brc != 0)) || [[ $out != +([0-9])' '+([0-9]) ]] ||
	    ! zfs unmount $ds >> $f.err 2>&1; then
		# Restore even if mdb's echo wasn't recognized: the write may
		# still have happened.
		((throttle != 0)) && act_asyncdestroy_tune 0xffffffffffffffff
		print "asyncdestroy: building $ds failed: $(tail -1 $f.err)"
		return 1
	fi
	zpool sync $POOL
	ref=$(zfs get -Hp -o value referenced $ds 2> /dev/null)
	# iteration, files, files overwritten after @s, referenced, throttle,
	# whether it was set, flush, setup seconds
	print "$it $out ${ref:--} $throttle $tuned $flush" \
	    "$(printf %.1f $((SECONDS - s)))" > $f.setup
	return 0
}

function act_asyncdestroy_start
{
	typeset f=$DIR/act_asyncdestroy i n o r throttle tuned flush secs

	[[ -s $f.setup ]] || return 0
	read i n o r throttle tuned flush secs < $f.setup
	[[ $i == $it ]] || return 0
	# Pass the drawn throttle even if setup's write wasn't confirmed, so
	# that the stream restores the default whenever it may have been set.
	stream python3 $f.py destroy $POOL/asyncdestroy $POOL $f.log $flush \
	    $throttle >> $f.err 2>&1
}

function act_asyncdestroy_verify
{
	typeset f=$DIR/act_asyncdestroy ds=$POOL/asyncdestroy
	typeset i nfiles nover ref0 throttle tuned flush secs
	typeset snaprc headrc snapms headms restored flushrc err phase fr0 ref1
	typeset freeing=- leaked=- feat=- bad="" head snap tune hd drain
	typeset wrc=running
	typeset -i wp n
	typeset -F s

	if [[ ! -s $f.setup ]]; then
		print "asyncdestroy: not set up"
		return 0
	fi
	read i nfiles nover ref0 throttle tuned flush secs < $f.setup
	if [[ $i != $it ]]; then
		print "asyncdestroy: not set up in iteration $it"
		return 0
	fi
	snaprc=$(nawk '$1 == "snap" { print $2 }' $f.log 2> /dev/null)
	snapms=$(nawk '$1 == "snap" { printf("%d", ($4 - $3) / 1000000) }' \
	    $f.log 2> /dev/null)
	headrc=$(nawk '$1 == "head" { print $2 }' $f.log 2> /dev/null)
	headms=$(nawk '$1 == "head" { printf("%d", ($4 - $3) / 1000000) }' \
	    $f.log 2> /dev/null)
	restored=$(nawk '$1 == "restored" { print $2 }' $f.log 2> /dev/null)
	flushrc=$(nawk '$1 == "flush" { print $2 }' $f.log 2> /dev/null)
	err=$(nawk '$1 == "error" || $1 == "mdb" { print; exit }' $f.log \
	    2> /dev/null)
	phase=$(nawk '$1 == "BUCKETS" { sub("phase=", "", $2); print $2; exit }' \
	    $DIR/d.out 2> /dev/null)
	fr0=$(zpool get -Hp -o value freeing $POOL 2> /dev/null)

	# A tunable that wasn't set or restored isn't a ZFS failure, so it is
	# only noted in the line.
	tune=unthrottled
	((tuned)) || tune="unthrottled (default not confirmed, see $f.mdb)"
	if ((throttle != 0)); then
		tune="throttle $throttle"
		((tuned)) || tune="$tune (not confirmed)"
		if [[ $restored == 1 ]]; then
			tune="$tune, restored by the stream"
		elif act_asyncdestroy_tune 0xffffffffffffffff; then
			tune="$tune, restored by verify"
		else
			tune="$tune, RESTORE FAILED (see $f.mdb)"
		fi
	fi

	# A destroy that returned 0 committed its txg.  "zfs list" failing
	# for some other reason reads as "gone", which can only hide a bug.
	head=gone
	zfs list -H -o name $ds > /dev/null 2>&1 && head=there
	snap=gone
	zfs list -H -t snapshot -o name $ds@s > /dev/null 2>&1 && snap=there
	if [[ $headrc == 0 && $head == there ]]; then
		bad="$ds is there, but its destroy returned 0"
	elif [[ $snaprc == 0 && $snap == there ]]; then
		bad="$ds@s is there, but its destroy returned 0"
	elif [[ $head == there ]]; then
		ref1=$(zfs get -Hp -o value referenced $ds 2> /dev/null)
		if [[ $ref0 != - && -n $ref1 && $ref1 != $ref0 ]]; then
			bad="$ds is there, but references $ref1 bytes, not $ref0"
		fi
		head="there (ref ${ref1:-?})"
	fi

	# Every free drains.  With zfs_async_block_max_blocks back at its
	# default, the rest of the bptree goes in one txg.  zpool wait alone
	# would do, but polling "freeing" too copes with a zpool wait that
	# fails, and with a destroy that another activity's verify just did.
	s=$SECONDS
	zpool wait -t free $POOL > /dev/null 2>&1 &
	wp=$!
	while :; do
		zpool get -Hp -o property,value freeing,leaked,feature@async_destroy \
		    $POOL 2> /dev/null | nawk '
		    { v[$1] = $2 }
		    END {
			split("freeing leaked feature@async_destroy", k, " ")
			for (i = 1; i <= 3; i++)
				printf("%s ", v[k[i]] == "" ? "-" : v[k[i]])
			printf("\n")
		    }' | read freeing leaked feat
		if [[ $wrc == running ]] && ! kill -0 $wp 2> /dev/null; then
			wait $wp
			wrc=$?
		fi
		# "-": zpool get failed, so only zpool wait says.
		[[ $wrc != running && ($freeing == 0 || $freeing == -) ]] &&
		    break
		((SECONDS - s > 60)) && break
		sleep 0.5
	done
	if [[ $wrc == running ]]; then
		# Don't block on a zpool wait stuck in the kernel: give it 2 s
		# to die, and leave it (the failure below stops the run).
		kill $wp 2> /dev/null
		n=4
		while kill -0 $wp 2> /dev/null && ((n-- > 0)); do
			sleep 0.5
		done
		kill -0 $wp 2> /dev/null || wait $wp 2> /dev/null
	fi
	drain=$(printf %.1f $((SECONDS - s)))
	if [[ -z $bad ]]; then
		if [[ $wrc == running ]]; then
			bad="frees did not drain in 60 s (zpool wait -t free still waiting, freeing $freeing, async_destroy $feat)"
		elif [[ $freeing != 0 && $freeing != - ]]; then
			bad="freeing is still $freeing after zpool wait -t free returned $wrc (async_destroy $feat)"
		elif [[ $leaked != 0 && $leaked != - ]]; then
			bad="leaked is $leaked"
		fi
	fi

	if [[ -n $headrc ]]; then
		hd="head rc $headrc ($headms ms)"
	elif [[ $snaprc == 0 ]]; then
		hd="head rc ? (none logged)"
	else
		hd="head not tried"
	fi
	typeset d="$((nfiles * 256))+$((nover * 256)) blocks, $tune"
	d="$d, flush $flush${flushrc:+ (rc $flushrc)}, setup $secs s; snap rc ${snaprc:-?}"
	d="$d (${snapms:-?} ms), $hd${err:+ ($err)}; head $head, snap $snap;"
	d="$d freeing ${fr0:-?} at verify, drained in $drain s"
	d="$d (wait rc $wrc), leaked $leaked; fail phase ${phase:-?}"
	if [[ -n $bad ]]; then
		print -r -- "asyncdestroy FAILED: $bad; $d"
		return 1
	fi
	print -r -- "asyncdestroy ok: $d"
	return 0
}

#
# The helper (python3), written to $DIR/act_asyncdestroy.py by setup:
#
#   build <dir> <dataset> <pool> <max files> <budget s>
#	Write the 1 MB files into <dir> (the mounted <dataset>), snapshot, and
#	overwrite; print "<files> <files overwritten>".
#   destroy <dataset> <pool> <log> <flush> <throttle>
#	Flush the ARC if <flush> is 1, destroy <dataset>@s and then <dataset>,
#	logging "snap|head <errno> <start ns> <end ns>"; if <throttle> isn't 0,
#	restore zfs_async_block_max_blocks once nothing of <pool> is mounted
#	or 10 s after the start, logging "restored <1|0> <ns>".
#
function act_asyncdestroy_helper
{
	cat <<'EOF'
import ctypes
import os
import re
import subprocess
import sys
import time

MB = 1048576
RESTORE = b"zfs_async_block_max_blocks/Z 0xffffffffffffffff\n"
QUIET = {"stdout": subprocess.DEVNULL}


def now():
	return time.monotonic_ns()


def lzc():
	z = ctypes.CDLL("libzfs_core.so.1", use_errno=True)
	n = ctypes.CDLL("libnvpair.so.1", use_errno=True)
	vp = ctypes.c_void_p
	z.libzfs_core_init.argtypes = []
	z.libzfs_core_init.restype = ctypes.c_int
	z.lzc_destroy.argtypes = [ctypes.c_char_p]
	z.lzc_destroy.restype = ctypes.c_int
	z.lzc_destroy_snaps.argtypes = [vp, ctypes.c_int, ctypes.POINTER(vp)]
	z.lzc_destroy_snaps.restype = ctypes.c_int
	n.nvlist_alloc.argtypes = [ctypes.POINTER(vp), ctypes.c_uint,
	    ctypes.c_int]
	n.nvlist_alloc.restype = ctypes.c_int
	n.nvlist_add_boolean.argtypes = [vp, ctypes.c_char_p]
	n.nvlist_add_boolean.restype = ctypes.c_int
	n.nvlist_free.argtypes = [vp]
	n.nvlist_free.restype = None
	if z.libzfs_core_init() != 0:
		raise OSError(ctypes.get_errno(), "libzfs_core_init failed")
	return z, n


def destroy_snap(z, n, name):
	nvl = ctypes.c_void_p()
	if n.nvlist_alloc(ctypes.byref(nvl), 1, 0) != 0:	# NV_UNIQUE_NAME
		return -1
	if n.nvlist_add_boolean(nvl, name.encode()) != 0:
		n.nvlist_free(nvl)
		return -1
	errlist = ctypes.c_void_p()
	rc = z.lzc_destroy_snaps(nvl, 0, ctypes.byref(errlist))
	n.nvlist_free(nvl)
	return rc


def put(path, buf, flags):
	fd = os.open(path, flags, 0o644)
	try:
		mv = memoryview(buf)
		off = 0
		while off < len(buf):
			off += os.pwrite(fd, mv[off:], off)
	finally:
		os.close(fd)


def build(d, ds, pool, maxfiles, budget):
	lzc()		# fail setup, not start, if libzfs_core can't be used
	t0 = time.monotonic()
	a = b"\x5a" * MB
	nfiles = 0
	while nfiles < maxfiles:
		tb = time.monotonic()
		for i in range(nfiles, min(nfiles + 16, maxfiles)):
			put("%s/f%03d" % (d, i), a,
			    os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
		nfiles = min(nfiles + 16, maxfiles)
		subprocess.check_call(["zpool", "sync", pool], **QUIET)
		# Stop before a batch that would likely end past the budget,
		# so that a slow (lofi) pool doesn't overshoot it by a batch.
		t = time.monotonic()
		if t - t0 + (t - tb) > budget:
			break
	subprocess.check_call(["zfs", "snapshot", ds + "@s"], **QUIET)
	b = b"\xa5" * MB
	nover = min(8, nfiles // 2)
	for i in range(nover):
		put("%s/f%03d" % (d, i), b, os.O_WRONLY)
	subprocess.check_call(["zpool", "sync", pool], **QUIET)
	print(nfiles, nover)


def mounted(pool):
	try:
		with open("/etc/mnttab") as f:
			for line in f:
				x = line.split("\t")
				if len(x) > 2 and x[2] == "zfs" and (x[0] == pool or
				    x[0].startswith(pool + "/") or
				    x[0].startswith(pool + "@")):
					return True
	except OSError:
		pass
	return False


def destroy(ds, pool, log, flush, throttle):
	out = open(log, "w", buffering=1)
	t0 = now()
	out.write("start %d %d\n" % (os.getpid(), t0))
	mdb = None
	if throttle != 0:
		# Load mdb now, so that the restore below is quick.
		try:
			mdb = subprocess.Popen(["mdb", "-kw"],
			    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
			    stderr=subprocess.STDOUT)
		except OSError as e:
			out.write("mdb error %d\n" % e.errno)
	try:
		z, n = lzc()
		if flush:
			t = now()
			try:
				rc = subprocess.call(["zinject", "-a"],
				    stdout=subprocess.DEVNULL,
				    stderr=subprocess.DEVNULL)
			except OSError as e:
				rc = -e.errno
			out.write("flush %d %d %d\n" % (rc, t, now()))
		t = now()
		rc = destroy_snap(z, n, ds + "@s")
		out.write("snap %d %d %d\n" % (rc, t, now()))
		if rc == 0:
			t = now()
			rc = z.lzc_destroy(ds.encode())
			out.write("head %d %d %d\n" % (rc, t, now()))
	except Exception as e:
		out.write("error %s\n" % str(e).replace("\n", " "))
	if mdb is not None:
		# Keep the throttle until the export has unmounted the pool
		# (or for 10 s): only a pool that hasn't failed frees anything.
		while now() - t0 < 10 * 10**9 and mounted(pool):
			time.sleep(0.1)
		ok = 0
		try:
			o, _ = mdb.communicate(RESTORE, timeout=3)
			if re.search(rb"0x[0-9a-f]+\s*=\s*0x[0-9a-f]+", o):
				ok = 1
		except Exception:
			mdb.kill()
		out.write("restored %d %d\n" % (ok, now()))
	out.write("done %d\n" % now())


if sys.argv[1] == "build":
	build(sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]),
	    float(sys.argv[6]))
elif sys.argv[1] == "destroy":
	destroy(sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]),
	    int(sys.argv[6]))
else:
	sys.exit(2)
EOF
}
