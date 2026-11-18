#
# act_crucible.sh: chaos activity "crucible", sourced by chaos.sh.
#
# A Crucible-downstairs-like region workload.  Crucible keeps each region of
# a virtual disk as raw extent files in a dataset of its own on a U.2 pool
# (oxp_*/crucible/regions/<id>: compression off, 128K records, a reservation
# of 1.25x the region and a quota), writes guest blocks into the extents
# (4 KiB writes into 128K records, so a read-modify-write of every record
# that isn't cached), fsyncs the extents on a guest flush, and takes region
# snapshots that live a long time (crucible downstairs/src/extent_inner_raw.rs,
# agent/src/main.rs).  Here:
#
# - $POOL/crucible/r0 (compression=off, recordsize 128k, reservation=20m,
#   quota=128m, primarycache=metadata in 3 iterations in 4, so that a
#   write's read of its record goes to the disk) holds 8 extents of 512 4 KiB
#   blocks (16 MiB), created by setup at generation 0 and snapshotted as
#   @base, the long-lived snapshot.
# - Two writers (holders), each a downstairs owning 4 extents, do what
#   Crucible's raw extent does: set an extent's dirty byte and fsync before
#   its first write after a flush; write a block's 32-byte context into its
#   inactive slot, then the block (1-4 blocks at a time); fsync first if a
#   block was written since its extent's last fsync (Crucible's "bonus
#   sync", crucible#1788); and every 4, 16 or 64 writes (drawn per
#   iteration), or 50 ms, flush: write the active-slot bitmap and the
#   metadata (clean, flush number) in one pwrite, then fsync, for each dirty
#   extent.  A quarter of their operations are reads, which must return what
#   they last wrote.  They never use O_DSYNC, so every write is logged as
#   WR_NEED_COPY (zfs_log_write()), and many are split across log blocks
#   (LR_WRITE_MORE/CONT).  After each fsync that returns 0 a writer logs the
#   blocks it acknowledged ($DIR/act_crucible.w[01].log).  On its first
#   error it logs it and holds its descriptors.
# - A snapshot loop (a stream) snapshots the region every 0.1-0.4 s, keeps
#   the newest 3 (2 on lofi1) and destroys the older ones, so the writers'
#   overwrites put data blocks into deadlists, and logs each command's start
#   time and rc ($DIR/act_crucible.snap.log).  It stops at the first nonzero
#   rc.
# - A reader (a holder) reads random ranges of the extents in @base (through
#   .zfs/snapshot, from the disk when primarycache=metadata), which must be
#   what setup wrote, or fail ($DIR/act_crucible.rd.log).
#
# Verify, after the import and zfs mount -a (all of it fails only on what
# ZFS promises; see the rules below):
# - no read, by a writer or the reader, returned wrong data (zeros from a
#   poisoned buffer, a stale generation, or a short read) instead of an error;
# - no fsync that started after the pool failed (spa_fail in $DIR/d.out,
#   plus 200 ms) returned 0;
# - the live region is mounted (zfs mount -a replayed its log);
# - in every extent of the live region (the last synced txg plus the replayed
#   log): every block is whole (a header of its own extent, block and some
#   generation, repeated); every acknowledged block is at its acknowledged
#   generation or later; one of its two context slots matches its generation;
#   the metadata's flush number is at least the last acknowledged flush, the
#   dirty byte is set if its acknowledged set is the last metadata change
#   acknowledged, and if the extent is clean, the bitmap's active slot of
#   each block matches it;
# - every snapshot whose "zfs snapshot" returned 0 exists unless a destroy of
#   it was tried, and every one whose "zfs destroy" returned 0 does not;
#   @base exists and is exactly what setup wrote;
# - each of the newest 4 region snapshots that exist passes the same checks
#   as the live region, against the acknowledgements whose fsync returned
#   before its "zfs snapshot" started.
# It prints one line; the details go to $DIR/act_crucible.verify.out, and on
# a failure it copies $DIR/act_crucible.* to $DIR/fail.$it.
#
# Rules the checks depend on:
# - An fsync that returns 0 makes durable every write to the file that
#   returned before it started (zil_commit(), zfs_fsync()).
# - Per file, what survives a failure is a prefix of the writes made to it
#   one after another: the synced txgs hold a prefix (each write's txg is no
#   earlier than the one before it), and the log replays, in order, the
#   records of later txgs up to the first log block that didn't land.  A
#   WR_NEED_COPY record copies the data when it is committed, not when it is
#   written, but no write here overwrites a range whose previous write is
#   unacknowledged (the bonus sync, the fsync after the dirty byte and after
#   each flush), so a record never carries a later write's data.  The
#   context and bitmap checks depend on this.
# - A 4 KiB block is never torn: a write of up to 16 KiB is one record per
#   128K record it touches, and a record split across log blocks is
#   replayed whole or not at all (zil_replay_split(), illumos 18512).
# - On a failed pool, open context gets EIO for a block it can't read or
#   that was poisoned, never zeros (dbuf_read_poison()), so a read returns
#   the right data or fails.
# - A snapshot holds every write that returned before "zfs snapshot"
#   started: the snapshot's sync task is in that write's txg or a later one.
# - A sync task that returns 0 has its txg committed (dsl_sync_task(),
#   zcp_eval() for the snapshot destroy); one that returns an error may
#   still have landed.  "zfs destroy" of a snapshot returns nonzero for every
#   ioctl error (zfs_destroy_snaps_nvl()), unlike a file system destroy.
#
# Space: the region is 17 MiB (8 x 17 records of 128K); the live region,
# @base and at most 4 rotating snapshots (3 kept plus the one made before the
# oldest is destroyed, which an uncommitted destroy can leave) hold at most
# about 102 MiB, usually much less, so the 128 MiB quota should never
# return EDQUOT (dsl_dir_tempreserve_impl() returns it only once the space
# actually used reaches the quota), to the writers or to the replay at the
# next mount.  It does throttle: each record first dirtied in a txg
# reserves 24 x 128K against it (spa_asize_inflation), so once the in-flight
# estimate reaches the quota, dmu_tx_assign() waits for the next txg
# (ERESTART), as Crucible's 3x quota does in production.
#
# Not checked: the generation upper bound (a block or snapshot holding a
# write that started after the snapshot or the failure), and the context
# slot of a block's other, older generation.  The harness's duplicate-DVA
# scan of the logs to claim doesn't cover $POOL/crucible/r0.
#

function act_crucible_setup
{
	typeset p=$DIR/act_crucible ds=$POOL/crucible/r0 pc=metadata

	[[ -n $DIR && -n $POOL ]] || { print "crucible: DIR or POOL unset"; return 1; }
	rm -f $p.*
	if ! act_crucible_py > $p.py; then
		print "crucible: cannot write $p.py"
		return 1
	fi
	((RANDOM % 4 == 0)) && pc=all
	print "pc=$pc" > $p.params
	# Another activity may have created $POOL/crucible already.
	if ! zfs list -H -o name $POOL/crucible > /dev/null 2>&1 &&
	    ! zfs create -o compression=off $POOL/crucible >> $p.err 2>&1; then
		print "crucible: zfs create $POOL/crucible failed: $(tail -1 $p.err)"
		return 1
	fi
	# recordsize explicitly: $POOL/crucible may come from another activity.
	if ! zfs create -o compression=off -o recordsize=128k \
	    -o reservation=20m -o quota=128m -o primarycache=$pc $ds \
	    >> $p.err 2>&1; then
		print "crucible: zfs create $ds failed: $(tail -1 $p.err)"
		return 1
	fi
	if ! python3 $p.py init /$ds >> $p.err 2>&1; then
		print "crucible: creating the extents failed: $(tail -1 $p.err)"
		return 1
	fi
	if ! zfs snapshot $ds@base >> $p.err 2>&1; then
		print "crucible: zfs snapshot $ds@base failed: $(tail -1 $p.err)"
		return 1
	fi
	return 0
}

function act_crucible_start
{
	typeset p=$DIR/act_crucible ds=$POOL/crucible/r0
	typeset -i s=$RANDOM n keep=3

	case $((RANDOM % 3)) in
	0)	n=4 ;;
	1)	n=16 ;;
	*)	n=64 ;;
	esac
	[[ $shape == lofi1 ]] && keep=2
	print "nflush=$n keep=$keep seed=$s" >> $p.params
	holder python3 $p.py write /$ds $p.w0.log $s $n 0 1 2 3 >> $p.err 2>&1
	holder python3 $p.py write /$ds $p.w1.log $((s + 1)) $n 4 5 6 7 \
	    >> $p.err 2>&1
	holder python3 $p.py read /$ds/.zfs/snapshot/base $p.rd.log $((s + 2)) \
	    >> $p.err 2>&1
	stream python3 $p.py snap $ds $p.snap.log $((s + 3)) $keep >> $p.err 2>&1
	return 0
}

function act_crucible_verify
{
	typeset p=$DIR/act_crucible ds=$POOL/crucible/r0 failns line m
	typeset -i rc

	if [[ ! -f $p.py || ! -f $p.params ]]; then
		print "crucible: $p.py or $p.params is missing (setup did not run)"
		return 0
	fi
	failns=$(nawk '$1 == "spa_fail" { print $2; exit }' $DIR/d.out 2>/dev/null)
	line=$(python3 $p.py verify $ds /$ds $p ${failns:-0} 2>> $p.err)
	rc=$?
	# Unmount the snapshots that verify read, before the harness's export.
	for m in $(mount -p | nawk -v s="$ds@" 'index($1, s) == 1 { print $3 }'); do
		umount $m > /dev/null 2>&1
	done
	[[ -z $line ]] && line="crucible: verify printed nothing (rc $rc, see $p.err)"
	print -r -- "$line"
	# 3 is a failure; anything else nonzero is a bug in verify itself, which
	# it reports in its line, and which must not stop the run.
	if ((rc == 3)); then
		mkdir -p $DIR/fail.$it && cp $p.* $DIR/fail.$it/ 2>/dev/null
		return 1
	fi
	return 0
}

# act_crucible_py: print the python helper (setup writes it to $DIR)
function act_crucible_py
{
	cat <<'ACT_CRUCIBLE_PY'
#
# act_crucible.py: the processes of chaos's "crucible" activity (see
# act_crucible.sh, which writes this file at setup).
#
#   init <dir>
#	Create the extents, every block at generation 0.
#   write <dir> <log> <seed> <nflush> <extent>...
#	A downstairs writing those extents (a holder).  After each fsync that
#	returns 0 it logs
#	    A <extent> <D|S|F> <flush#> <t0> <t1> <block:gen,...|-> .
#	(D: the dirty byte, S: a bonus sync, F: a flush) with the blocks
#	written since the extent's previous fsync.  A read that returns wrong
#	data logs "bad ...".  On its first error it logs "err ..." and holds.
#   read <dir> <log> <seed>
#	Read random ranges of the extents as init wrote them (in a snapshot),
#	logging "bad ..." for wrong data, "n <count>" now and then, and
#	"err ..." at its first error, then hold (a holder).
#   snap <dataset> <log> <seed> <keep>
#	Snapshot the dataset as @c0, @c1, ... every 0.1-0.4 s, keeping the
#	newest <keep>, logging "s <i> <t0> ." before and "S <i> <t0> <t1>
#	<rc> ." after each snapshot (d/D for the destroys), until a command
#	fails (a stream).
#   verify <dataset> <dir> <prefix> <fail ns>
#	Check the region at <dir> and its snapshots against the logs
#	<prefix>.*.  Prints one line; exits 0 if all is well, 3 on a failure,
#	2 if verify itself broke.
#
# Times are time.monotonic_ns(), which is gethrtime(), DTrace's timestamp.
#
import hashlib
import os
import random
import signal
import struct
import subprocess
import sys
import time

BS = 4096		# a block
NB = 512		# blocks per extent: 2 MiB, 16 records of 128K
NE = 8			# extents
SLOT = 32		# a context slot
DATA = NB * BS		# the blocks
CTX = DATA		# then two arrays of NB context slots
BITMAP = CTX + 2 * NB * SLOT	# then the active slot of each block
META = BITMAP + NB // 8		# then the metadata; byte 0 is "dirty"
SIZE = META + 32
HDR = struct.Struct("<8sIIQQ")	# magic, extent, block, generation, check
MREC = struct.Struct("<B7sQQQ")	# dirty, magic, flush number, 0, 0
NREP = BS // HDR.size
BMAGIC = b"CRUXBLK0"
CMAGIC = b"CRUXCTX0"
MMAGIC = b"CRUXMET"
FLUSH_NS = 50000000
# spa_fail's time in d.out is its entry, normally a few microseconds before
# the pool is FAILED (spa_fail_impl() takes spa_suspend_lock first, and its
# caller can be preempted in between); an fsync that starts within this
# margin after it may succeed.  zil_commit() checks spa_failed() on entry,
# after the fsync's t0, so a later fsync can't.  The margin costs nothing:
# a write that is assigned a txg after the failure fails before its fsync.
MARGIN_NS = 200000000
now = time.monotonic_ns


def chk(e, b, g):
	d = hashlib.sha256(struct.pack("<IIQ", e, b, g)).digest()
	return struct.unpack("<Q", d[:8])[0]


def block(e, b, g):
	"""Block b of extent e at generation g: its header, repeated."""
	return HDR.pack(BMAGIC, e, b, g, chk(e, b, g)) * NREP


def ctxrec(e, b, g):
	return HDR.pack(CMAGIC, e, b, g, chk(e, b, g))


def slot_off(s, b):
	return CTX + (s * NB + b) * SLOT


def bitmap(act):
	m = bytearray(NB // 8)
	for b in range(NB):
		if act[b]:
			m[b >> 3] |= 1 << (b & 7)
	return bytes(m)


def metarec(dirty, flush):
	return MREC.pack(dirty, MMAGIC, flush, 0, 0)


def image0(e):
	"""Extent e as init writes it."""
	img = bytearray(SIZE)
	img[0:DATA] = b"".join(block(e, b, 0) for b in range(NB))
	for b in range(NB):
		o = slot_off(0, b)
		img[o:o + SLOT] = ctxrec(e, b, 0)
	img[META:META + MREC.size] = metarec(0, 0)
	return bytes(img)


def path(d, e):
	return "%s/e%d" % (d, e)


def describe(blk):
	"""A token describing a block read back."""
	if not blk.strip(b"\0"):
		return "zeros%d" % len(blk)
	if len(blk) < HDR.size:
		return "short%d" % len(blk)
	m, e, b, g, c = HDR.unpack(blk[:HDR.size])
	whole = (m == BMAGIC and c == chk(e, b, g) and
	    blk == blk[:HDR.size] * NREP)
	return "%s/e%d/b%d/g%d/%s/len%d" % (m.hex(), e, b, g,
	    "whole" if whole else "torn", len(blk))


class Log:
	"""A log written a whole line per write(2)."""

	def __init__(self, p):
		self.fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC |
		    os.O_APPEND, 0o644)

	def __call__(self, *args):
		os.write(self.fd, (" ".join(str(a) for a in args) +
		    "\n").encode())


def hold(log, *what):
	"""Log what, then keep every descriptor open until killed."""
	log(*what)
	while True:
		signal.pause()


class Short(Exception):
	pass


def full(n, want):
	if n != want:
		raise Short("%d/%d" % (n, want))


def init(d):
	for e in range(NE):
		with open(path(d, e), "xb") as f:
			f.write(image0(e))


def write(d, log, seed, nflush, extents):
	rnd = random.Random(seed)
	out = Log(log)
	gen = dict((e, [0] * NB) for e in extents)	# last written
	act = dict((e, bytearray(NB)) for e in extents)	# active slots
	pend = dict((e, {}) for e in extents)	# written since last fsync
	dirty = dict((e, False) for e in extents)
	fds = {}
	st = {"flush": 0, "ops": 0, "reads": 0}

	def fsync(e, kind, n):
		t0 = now()
		os.fsync(fds[e])
		t1 = now()
		bl = ",".join("%d:%d" % bg for bg in sorted(pend[e].items()))
		out("A", e, kind, n, t0, t1, bl or "-", ".")
		pend[e].clear()

	out("start", os.getpid(), now(), "nflush", nflush)
	try:
		for e in extents:
			fds[e] = os.open(path(d, e), os.O_RDWR)
		last = now()
		while True:
			e = rnd.choice(extents)
			fd = fds[e]
			n = 1 if rnd.random() < 0.7 else rnd.randint(2, 4)
			b0 = rnd.randrange(NB - n + 1)
			if rnd.random() < 0.25:
				# A guest read: what was last written, or
				# an error.
				got = os.pread(fd, n * BS, b0 * BS)
				for i in range(n):
					b = b0 + i
					have = got[i * BS:(i + 1) * BS]
					if have != block(e, b, gen[e][b]):
						hold(out, "bad", e, b,
						    gen[e][b], len(got),
						    describe(have), now())
				st["reads"] += 1
				continue
			if not dirty[e]:
				full(os.pwrite(fd, b"\x01", META), 1)
				fsync(e, "D", 0)
				dirty[e] = True
			if any(b0 + i in pend[e] for i in range(n)):
				fsync(e, "S", 0)
			for i in range(n):
				b = b0 + i
				full(os.pwrite(fd, ctxrec(e, b, gen[e][b] + 1),
				    slot_off(act[e][b] ^ 1, b)), SLOT)
			data = b"".join(block(e, b0 + i, gen[e][b0 + i] + 1)
			    for i in range(n))
			full(os.pwrite(fd, data, b0 * BS), len(data))
			for i in range(n):
				b = b0 + i
				gen[e][b] += 1
				act[e][b] ^= 1
				pend[e][b] = gen[e][b]
			st["ops"] += 1
			if st["ops"] % nflush == 0 or now() - last > FLUSH_NS:
				st["flush"] += 1
				for f in extents:
					if not dirty[f]:
						continue
					rec = bitmap(act[f]) + \
					    metarec(0, st["flush"])
					full(os.pwrite(fds[f], rec, BITMAP),
					    len(rec))
					fsync(f, "F", st["flush"])
					dirty[f] = False
				last = now()
	except OSError as x:
		what = ["err", x.errno]
	except Short as x:
		what = ["err", "short" + str(x)]
	for e in extents:
		if pend[e]:
			out("pending", e, ",".join("%d:%d" % bg
			    for bg in sorted(pend[e].items())))
	hold(out, *(what + [now(), "ops", st["ops"], "reads", st["reads"]]))


def read(d, log, seed):
	rnd = random.Random(seed)
	out = Log(log)
	imgs = {}
	fds = {}
	n = 0
	out("start", os.getpid(), now())
	try:
		for e in range(NE):
			fds[e] = os.open(path(d, e), os.O_RDONLY)
		while True:
			for _ in range(8):
				e = rnd.randrange(NE)
				if e not in imgs:
					imgs[e] = image0(e)
				if rnd.random() < 0.9:
					k = rnd.randint(1, 4) * BS
					off = rnd.randrange(NB - k // BS + 1) * BS
				else:
					off = rnd.randrange(CTX // 512,
					    SIZE // 512) * 512
					k = min(BS, SIZE - off)
				got = os.pread(fds[e], k, off)
				want = imgs[e][off:off + k]
				if got != want:
					i = 0
					while i < min(len(got), k) and \
					    got[i] == want[i]:
						i += 1
					o = off + i - (off + i) % BS
					what = describe(got[o - off:o - off + BS]) \
					    if o < DATA else "tail"
					hold(out, "bad", e, off, k, len(got),
					    off + i, what, now())
				n += 1
				if n % 1000 == 0:
					out("n", n, now())
			time.sleep(0.01)
	except OSError as x:
		hold(out, "err", x.errno, now(), "reads", n)


def zfs(*args):
	try:
		return subprocess.run(("zfs",) + args,
		    stdout=subprocess.DEVNULL).returncode
	except OSError:
		return -1


def snap(ds, log, seed, keep):
	rnd = random.Random(seed)
	out = Log(log)
	kept = []
	end = now() + 120 * 1000000000
	out("start", os.getpid(), now())
	i = 0
	while i < 500 and now() < end:
		t0 = now()
		out("s", i, t0, ".")
		rc = zfs("snapshot", "%s@c%d" % (ds, i))
		out("S", i, t0, now(), rc, ".")
		if rc != 0:
			break
		kept.append(i)
		while rc == 0 and len(kept) > keep:
			j = kept.pop(0)
			t0 = now()
			out("d", j, t0, ".")
			rc = zfs("destroy", "%s@c%d" % (ds, j))
			out("D", j, t0, now(), rc, ".")
		if rc != 0:
			break
		i += 1
		time.sleep(rnd.uniform(0.1, 0.4))
	out("end", now())


def parse_ack(f):
	"""An "A" log line's fields, or None if it isn't a whole one."""
	if len(f) != 8 or f[0] != "A" or f[7] != "." or \
	    f[2] not in ("D", "S", "F"):
		return None
	try:
		e, n, t0, t1 = int(f[1]), int(f[3]), int(f[4]), int(f[5])
		bl = []
		if f[6] != "-":
			for x in f[6].split(","):
				b, g = x.split(":")
				bl.append((int(b), int(g)))
	except ValueError:
		return None
	if not 0 <= e < NE or any(not 0 <= b < NB or g < 1 for b, g in bl):
		return None
	return (e, f[2], n, t0, t1, bl)


def lines(p):
	try:
		with open(p) as f:
			return f.read().splitlines()
	except FileNotFoundError:
		return None


def readfile(p, tries=1):
	"""
	The file's contents.  A snapshot's file is read through its automount;
	give that a second chance before calling the snapshot unreadable.
	"""
	for t in range(tries):
		try:
			with open(p, "rb") as f:
				return f.read()
		except OSError:
			if t == tries - 1:
				raise
			time.sleep(0.5)


def check_image(e, img, acks, where):
	"""
	What is wrong with an image of extent e that must hold the
	acknowledgements acks (in the order they were made), and how many of
	its blocks are past generation 0.  Every check but the first two
	(whole blocks, acknowledged generations) depends on the prefix rule
	(see act_crucible.sh).
	"""
	if len(img) != SIZE:
		return (["%s/e%d: %d bytes, not %d" % (where, e, len(img),
		    SIZE)], 0)
	need = {}
	nflush, last = 0, "F"	# init's state counts as flush 0
	for kind, n, t0, t1, bl in acks:
		for b, g in bl:
			need[b] = max(need.get(b, 0), g)
		if kind == "F":
			nflush, last = n, "F"
		elif kind == "D":
			last = "D"
	gens = [None] * NB
	torn, lost, noctx, badmap = [], [], [], []
	for b in range(NB):
		blk = img[b * BS:(b + 1) * BS]
		m, he, hb, g, c = HDR.unpack(blk[:HDR.size])
		if m != BMAGIC or he != e or hb != b or c != chk(e, b, g) or \
		    blk != blk[:HDR.size] * NREP:
			torn.append("b%d=%s" % (b, describe(blk)))
			continue
		gens[b] = g
		if g < need.get(b, 0):
			lost.append("b%d=g%d<g%d" % (b, g, need[b]))
		want = ctxrec(e, b, g)
		if want != img[slot_off(0, b):slot_off(0, b) + SLOT] and \
		    want != img[slot_off(1, b):slot_off(1, b) + SLOT]:
			noctx.append("b%d/g%d" % (b, g))
	probs = []
	w = "%s/e%d" % (where, e)
	if torn:
		probs.append("%s: %d blocks torn or zeroed (%s)" % (w,
		    len(torn), " ".join(torn[:3])))
	if lost:
		probs.append("%s: %d acknowledged blocks lost (%s)" % (w,
		    len(lost), " ".join(lost[:4])))
	if noctx:
		probs.append("%s: %d blocks match neither context slot (%s)" %
		    (w, len(noctx), " ".join(noctx[:4])))
	dirty, mm, flush, z1, z2 = MREC.unpack(img[META:META + MREC.size])
	if mm != MMAGIC or dirty not in (0, 1):
		probs.append("%s: bad metadata %s" % (w,
		    img[META:META + MREC.size].hex()))
	elif flush < nflush:
		probs.append("%s: flush number %d, but flush %d was "
		    "acknowledged" % (w, flush, nflush))
	elif last == "D" and flush == nflush and dirty == 0:
		probs.append("%s: the dirty byte acknowledged after flush %d "
		    "is clear" % (w, nflush))
	elif dirty == 0:
		# Clean: the last metadata write that landed is the flush
		# number's, and nothing written after it landed (the next
		# write needs an acknowledged dirty byte first).
		for b in range(NB):
			if gens[b] is None:
				continue
			s = (img[BITMAP + (b >> 3)] >> (b & 7)) & 1
			if img[slot_off(s, b):slot_off(s, b) + SLOT] != \
			    ctxrec(e, b, gens[b]):
				badmap.append("b%d/g%d/s%d" % (b, gens[b], s))
		if badmap:
			probs.append("%s: clean at flush %d, but %d active "
			    "slots don't match (%s)" % (w, flush, len(badmap),
			    " ".join(badmap[:4])))
	return (probs, sum(1 for g in gens if g))


def verify(ds, d, p, fail):
	probs, notes = [], []
	params = " ".join(" ".join(lines(p + ".params") or []).split())

	# The writers' acknowledgements, per extent in order.
	acks = dict((e, []) for e in range(NE))
	wsum = []
	for w in (0, 1):
		ls = lines("%s.w%d.log" % (p, w))
		if ls is None:
			wsum.append("w%d no log" % w)
			continue
		na = nb = 0
		end = "no error"
		for line in ls:
			f = line.split()
			if not f:
				continue
			a = parse_ack(f)
			if a is not None:
				acks[a[0]].append(a[1:])
				na += 1
				nb += len(a[5])
			elif f[0] == "bad":
				probs.append("w%d READ BACK WRONG DATA: %s" %
				    (w, line))
			elif f[0] == "err":
				end = " ".join(f[:2])
		wsum.append("w%d %d fsyncs %d blocks %s" % (w, na, nb, end))
	notes.append("; ".join(wsum))

	if fail > 0:
		late = []
		for e in range(NE):
			for kind, n, t0, t1, bl in acks[e]:
				if t0 > fail + MARGIN_NS:
					late.append("e%d/%s%d+%dms" % (e, kind, n,
					    (t0 - fail) // 1000000))
		if late:
			probs.append("%d FSYNCS THAT STARTED AFTER THE POOL "
			    "FAILED RETURNED 0 (%s)" % (len(late),
			    " ".join(late[:4])))

	# The live region: the last synced txg plus the replayed log.  It was
	# created in a synced txg (setup's @base), so "zfs mount -a" must have
	# mounted it, replaying its log; if it didn't, the replay failed.
	newer = 0
	mounted = os.path.ismount(d)
	if not mounted:
		probs.append("live: %s IS NOT MOUNTED after zfs mount -a (did "
		    "its log replay fail? see chaos.log)" % d)
	for e in range(NE if mounted else 0):
		try:
			img = readfile(path(d, e))
		except OSError as x:
			probs.append("live/e%d: %s" % (e, x))
			continue
		pr, k = check_image(e, img, acks[e], "live")
		probs += pr
		newer += k
	notes.append("live: %d blocks past setup" % newer)

	# The snapshot loop's results.
	snaps = {}
	ls = lines(p + ".snap.log") or []
	for line in ls:
		f = line.split()
		try:
			if len(f) == 4 and f[0] == "s" and f[3] == ".":
				snaps[int(f[1])] = {"t0": int(f[2]),
				    "rc": None, "d": False, "drc": None}
			elif len(f) == 6 and f[5] == "." and \
			    f[0] in ("S", "D") and int(f[1]) in snaps:
				k = "rc" if f[0] == "S" else "drc"
				snaps[int(f[1])][k] = int(f[4])
			elif len(f) == 4 and f[0] == "d" and f[3] == "." and \
			    int(f[1]) in snaps:
				snaps[int(f[1])]["d"] = True
		except ValueError:
			pass
	r = subprocess.run(["zfs", "list", "-H", "-o", "name", "-t",
	    "snapshot", "-d", "1", ds], stdout=subprocess.PIPE,
	    stderr=subprocess.PIPE)
	if r.returncode != 0:
		probs.append("zfs list of %s's snapshots failed: %s" % (ds,
		    r.stderr.decode(errors="replace").strip()[:120]))
		have = None
	else:
		have = set(x.split("@", 1)[1]
		    for x in r.stdout.decode().split() if "@" in x)
	ntaken = ndestroyed = nchecked = 0
	if have is not None:
		if "base" not in have:
			probs.append("@base IS MISSING")
		for i in sorted(snaps):
			s, name = snaps[i], "c%d" % i
			if s["rc"] != 0:
				continue
			ntaken += 1
			if s["drc"] == 0:
				ndestroyed += 1
				if name in have:
					probs.append("@%s: ITS DESTROY RETURNED "
					    "0, BUT IT EXISTS" % name)
			elif not s["d"] and name not in have:
				probs.append("@%s: ITS SNAPSHOT RETURNED 0, "
				    "BUT IT IS MISSING" % name)
		check = [i for i in sorted(snaps) if "c%d" % i in have][-4:]
		for e in range(NE):
			try:
				img = readfile(path("%s/.zfs/snapshot/base" % d,
				    e), 2)
			except OSError as x:
				probs.append("@base/e%d: %s" % (e, x))
				continue
			if img != image0(e):
				pr, k = check_image(e, img, [], "@base")
				probs.append("@base/e%d: NOT WHAT SETUP WROTE%s" %
				    (e, (" (" + pr[0] + ")") if pr else ""))
		for i in check:
			ts = snaps[i]["t0"]
			for e in range(NE):
				sp = "%s/.zfs/snapshot/c%d" % (d, i)
				try:
					img = readfile(path(sp, e), 2)
				except OSError as x:
					probs.append("@c%d/e%d: %s" % (i, e, x))
					continue
				pr, k = check_image(e, img,
				    [a for a in acks[e] if a[3] < ts],
				    "@c%d" % i)
				probs += pr
			nchecked += 1
	notes.append("snaps: %d taken, %d destroyed, %d checked%s" % (ntaken,
	    ndestroyed, nchecked, "" if ls else " (no log)"))

	# The reader of @base.
	ls = lines(p + ".rd.log")
	if ls is None:
		notes.append("reader: no log")
	else:
		nr, end = 0, "no error"
		for line in ls:
			f = line.split()
			if not f:
				continue
			if f[0] == "bad":
				probs.append("READER OF @base READ WRONG DATA: "
				    "%s" % line)
			elif f[0] == "err" and len(f) >= 5:
				end, nr = "err " + f[1], f[4]
			elif f[0] == "n" and len(f) >= 2:
				nr = f[1]
		notes.append("reader: %s reads, %s" % (nr, end))

	with open(p + ".verify.out", "w") as o:
		o.write("params: %s\n" % params)
		for x in notes + probs:
			o.write(x + "\n")
	if probs:
		more = " (+%d more in %s.verify.out)" % (len(probs) - 1, p) \
		    if len(probs) > 1 else ""
		print(("crucible: FAILED: %s" % probs[0])[:400] + more)
		return 3
	print("crucible: ok (%s): %s" % (params, "; ".join(notes)))
	return 0


def main(a):
	if a[0] == "init":
		init(a[1])
	elif a[0] == "write":
		write(a[1], a[2], int(a[3]), int(a[4]),
		    [int(x) for x in a[5:]])
	elif a[0] == "read":
		read(a[1], a[2], int(a[3]))
	elif a[0] == "snap":
		snap(a[1], a[2], int(a[3]), int(a[4]))
	elif a[0] == "verify":
		try:
			return verify(a[1], a[2], a[3], int(a[4]))
		except Exception as x:
			import traceback
			traceback.print_exc()
			print("crucible: VERIFY BROKE, NOTHING CHECKED: %r" %
			    (x,))
			return 2
	else:
		return 2
	return 0


sys.exit(main(sys.argv[1:]))
ACT_CRUCIBLE_PY
}
