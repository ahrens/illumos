#
# act_nschurn.sh: chaos activity "nschurn", sourced by chaos.sh.
#
# Namespace churn with directory fsync, the way Pebble (CockroachDB, which
# Oxide runs in $POOL/crypt/cockroachdb), Crucible's extent repair and debug
# collectors use a file system, while the pool fails.  Two instances of
# act_nschurn.py run as holders:
#   fs  in /$POOL/fs/nschurn, a directory of the fs dataset, so its log
#       records share a ZIL with the w0 (fsync) and w1 (O_DSYNC) writers;
#   cr  in /$POOL/crypt/nschurn/db, its own encrypted dataset
#       (recordsize=16k), so an encrypted ZIL holds them.
# Each iteration i retires (unlinks) what iteration i-16 made, 1 table in 4
# while a descriptor still holds it open; writes tmp.i (0-135000 bytes),
# fsyncs it (2 in 3) and renames it to sst.i; sometimes hard-links or
# symlinks it, replaces CURRENT (write, fsync, rename over), chmods and
# fsyncs the previous table, or builds a directory (mkdir stage.i, write and
# fsync stage.i/ext, fsync stage.i, rename it to reg.i); appends a record to
# a WAL or truncates it, and fsyncs the WAL; then fsyncs the directory.
# Every operation is logged before it is tried, and every fsync that
# returned 0 after it returned.  At the first error an instance logs it and
# holds its descriptors (the directory, the WAL, up to 8 unlinked tables,
# whatever was open) until the harness kills it after the export.
#
# setup creates the dataset and directories, runs the first 40 iterations
# on the healthy pool, syncs it, and then checks the verifier's model
# against that state, as logged and with the last 1-4 acks ignored, so that
# a model bug stops the run at its first setup rather than as a false
# failure after an import.
#
# verify, after the import and mount (which replays the ZIL), checks every
# name either instance ever used:
# - a namespace op (create, mkdir, symlink, link, rename, unlink, rmdir)
#   that a directory fsync acknowledged is reflected: the name is there with
#   the right kind, inode (content, link count, mode) or symlink target, or
#   is gone;
# - the content of a file is checked when an fsync of that file returned 0,
#   or when a directory fsync acknowledged its rename (see the rename rule
#   below); a chmod when an fsync of that file returned 0;
# - a name that ops after the last acknowledgment touched may be in any
#   state it had from that acknowledgment on, but in no other;
# - no name is there that was never created;
# - the WAL holds every record whose WAL fsync returned 0, and its size is
#   one it had from its last acknowledged fsync on (skipped when a truncate
#   is pending);
# - no fsync that started more than 1 ms after spa_fail returned 0.
# It prints one line; the details go to $DIR/act_nschurn.check.
#
# What the checks rely on (illumos ZFS, zfs_log.c and zil.c):
# - Every namespace op logs a synchronous itx (zil_itx_create()'s default),
#   and every zil_commit() commits all of a dataset's synchronous itxs, so
#   once an fsync of a directory returns 0, every namespace op before it is
#   on disk, in the ZIL or in a synced txg, and is there after the import
#   and replay.  An fsync of a file commits them too, but is not counted as
#   acknowledging them (that would only add checks).
# - Writes, truncates and setattrs (chmod) log asynchronous itxs of their
#   file (itx_sync = z_sync_cnt != 0): a directory fsync does not commit
#   them, only an fsync of that file does...
# - ...except that logging a rename first moves the renamed file's
#   asynchronous itxs to the synchronous list (zil_itx_assign(): "Ensure the
#   data of a renamed file is committed before the rename").  So a
#   directory fsync after a rename commits the data written before it, and
#   the content of the 1 in 3 tables that are never fsynced is checked once
#   such an fsync returned 0.  This is the one rule here that is specific to
#   ZFS; a failure that cites "rename" depends on it.
# - Ops after the last acknowledgment may or may not be there.  One thread
#   issues each instance's ops in order, its synchronous itxs are committed
#   in that order, and the import replays, after the last synced txg, a
#   prefix of the log chain, so the namespace comes back as the acknowledged
#   state plus a prefix of the later ops.  The check is weaker than that:
#   each name, separately, must be in a state it had at one of those
#   prefixes.
# - The WAL's size must be one it had at a WAL op boundary: a 4K append
#   that the log ends inside of is not replayed in part.  That relies on
#   zil_replay_split() (zil.c): a WR_NEED_COPY write split across log
#   blocks is replayed only once its last piece is there.  A size between
#   two boundaries means a write was partly applied.
# - zil_commit() returns EIO once the pool has failed, before and after it
#   waits, so an fsync that started after the failure can't return 0.  The
#   1 ms margin covers DTrace's spa_fail:entry timestamp, taken before
#   spa_fail_impl() stores SPA_EXIT_FAILED (the harness's writer check
#   uses no margin at all).
#
# Files: $DIR/act_nschurn.py (the helper, rewritten by every setup),
# $DIR/act_nschurn.setup (the iteration setup ran in),
# $DIR/act_nschurn.{fs,cr}.log (what was tried and acknowledged),
# $DIR/act_nschurn.check (the last self-check or verify),
# $DIR/act_nschurn.init.{fs,cr} (init's output), $DIR/act_nschurn.out
# (zfs and zpool output, and the run helpers' stderr).  On a failure,
# verify copies them all to $DIR/fail.$it.
#
# Known limits: the unlinked set is not checked to drain at the mount (the
# drain is asynchronous, and zdb -bcc counts its objects as referenced);
# the content of an unfsynced table whose rename was not acknowledged is
# not checked; the harness's dup-DVA scan doesn't cover crypt/nschurn; cr
# is skipped (and said so) if its key isn't available at verify.
#

function act_nschurn_setup
{
	typeset k=$DIR/act_nschurn s p1 p2 r1 r2

	[[ -n $DIR && -n $POOL ]] || { print "nschurn: DIR or POOL unset"; return 1; }
	rm -f $k.py $k.setup $k.fs.log $k.cr.log $k.check $k.out \
	    $k.init.fs $k.init.cr
	if ! act_nschurn_helper > $k.py; then
		print "nschurn: can't write $k.py"
		return 1
	fi
	# An fsync of a sync=disabled dataset returns 0 without committing.
	s=$(zfs get -H -o value sync $POOL/fs 2>&1)
	if [[ $s != standard && $s != always ]]; then
		print "nschurn: $POOL/fs has sync=$s"
		return 1
	fi
	if ! zfs create -o recordsize=16k -o sync=standard \
	    $POOL/crypt/nschurn > $k.out 2>&1; then
		print "nschurn: zfs create $POOL/crypt/nschurn failed: $(head -1 $k.out)"
		return 1
	fi
	# -I: nothing else in $DIR (the script's directory) can shadow a
	# module the helper imports.
	python3 -I $k.py init /$POOL/fs/nschurn $k.fs.log fs \
	    > $k.init.fs 2>&1 < /dev/null &
	p1=$!
	python3 -I $k.py init /$POOL/crypt/nschurn/db $k.cr.log cr \
	    > $k.init.cr 2>&1 < /dev/null &
	p2=$!
	wait $p1; r1=$?
	wait $p2; r2=$?
	if ((r1 != 0 || r2 != 0)); then
		print "nschurn: init failed: fs $r1 $(tail -1 $k.init.fs); cr $r2 $(tail -1 $k.init.cr)"
		return 1
	fi
	# What the first 40 iterations made is in a synced txg, so the checks
	# after the import don't depend on replaying setup's log records.
	if ! zpool sync $POOL >> $k.out 2>&1; then
		print "nschurn: zpool sync $POOL failed"
		return 1
	fi
	if ! python3 -I $k.py selfcheck /$POOL/fs/nschurn $k.fs.log fs \
	    /$POOL/crypt/nschurn/db $k.cr.log cr > $k.check 2>&1; then
		print "nschurn: self-check failed: $(tail -1 $k.check)"
		return 1
	fi
	print -r -- "${it:-0}" > $k.setup
	return 0
}

function act_nschurn_start
{
	typeset k=$DIR/act_nschurn

	# Each logs its first error (or a Python exception) to its own log.
	# Their own output goes to a file, so that they never hold open a
	# pipe that the caller reads to its end.
	holder python3 -I $k.py run /$POOL/fs/nschurn $k.fs.log fs \
	    >> $k.out 2>&1 < /dev/null
	holder python3 -I $k.py run /$POOL/crypt/nschurn/db $k.cr.log cr \
	    >> $k.out 2>&1 < /dev/null
	return 0
}

# act_nschurn_failed <message>: print it, save the evidence, and fail
function act_nschurn_failed
{
	print -r -- "$1"
	mkdir -p $DIR/fail.${it:-0} && cp $DIR/act_nschurn.* $DIR/fail.${it:-0}/ 2>/dev/null
	return 1
}

function act_nschurn_verify
{
	typeset k=$DIR/act_nschurn fail_ns ks mnt args line skip="" sit=""
	typeset -i rc

	# Logs left by another iteration's setup describe another pool.
	[[ -s $k.setup ]] && sit=$(< $k.setup)
	if [[ $sit != "${it:-0}" ]]; then
		print "nschurn: not set up in iteration ${it:-0}"
		return 0
	fi
	fail_ns=$(nawk '$1 == "spa_fail" { print $2; exit }' $DIR/d.out 2>/dev/null)
	args="/$POOL/fs/nschurn $k.fs.log fs"
	# zfs create returned 0, so crypt/nschurn is in a synced txg.  Its key
	# is crypt's: if the harness's load-key left it unavailable (another
	# activity's key rotation), cr is skipped rather than failed.
	if ! zfs list -H -o name $POOL/crypt/nschurn > /dev/null 2>&1; then
		act_nschurn_failed "nschurn FAILED: $POOL/crypt/nschurn is missing after the import"
		return
	fi
	ks=$(zfs get -H -o value keystatus $POOL/crypt/nschurn 2>/dev/null)
	if [[ $ks == available ]]; then
		mnt=$(zfs get -H -o value mounted $POOL/crypt/nschurn 2>/dev/null)
		if [[ $mnt != yes ]]; then
			zfs mount $POOL/crypt/nschurn >> $k.out 2>&1
			mnt=$(zfs get -H -o value mounted $POOL/crypt/nschurn 2>/dev/null)
		fi
		if [[ $mnt != yes ]]; then
			act_nschurn_failed "nschurn FAILED: $POOL/crypt/nschurn, its key loaded, did not mount"
			return
		fi
		args="$args /$POOL/crypt/nschurn/db $k.cr.log cr"
	else
		skip="; cr skipped (keystatus ${ks:-unknown})"
	fi
	# The verifier exits 3 on a failure.  Anything else nonzero is a bug
	# in it (a Python exception), which must not stop the run.
	python3 -I $k.py verify ${fail_ns:-0} $args > $k.check 2>&1 < /dev/null
	rc=$?
	line=$(tail -1 $k.check)
	if ((rc == 3)); then
		act_nschurn_failed "${line:-nschurn FAILED (see $k.check)}$skip"
		return
	fi
	if ((rc != 0)); then
		print -r -- "nschurn NOT CHECKED: the verifier exited $rc: $line$skip"
		return 0
	fi
	print -r -- "${line:-nschurn: no output from the verifier}$skip"
	return 0
}

# The helper.  python3 -m py_compile checks it once it's extracted.
function act_nschurn_helper
{
	cat <<'NSCHURN_PY_EOF'
#
# act_nschurn.py: the helper of act_nschurn.sh, whose setup writes it.
#
#   init <dir> <log> <tag>	create <dir>, run iterations 0 .. INIT-1
#   run <dir> <log> <tag>	run iterations INIT .. until the first error,
#				then hold every descriptor until killed
#   selfcheck (<dir> <log> <tag>)...
#				check the model against the healthy pool, as
#				logged and with the last 1-4 acks ignored
#   verify <fail ns> (<dir> <log> <tag>)...
#				check the namespace after import and replay;
#				exit 3 on a failure (1 is a Python exception)
#
# The log: "o ..." is written before the operation is tried, an ack after
# an fsync returned 0, with time.monotonic_ns() (gethrtime(), DTrace's
# timestamp) before and after the fsync:
#   o c <name>			create a file, O_EXCL, mode 644
#   o w <name> <key> <size>	write it: data(tag, key, size)
#   o mv <from> <to>		rename a file or directory
#   o rm|rmo|rd <name>		unlink, unlink while open, rmdir
#   o ln <from> <to>		hard link
#   o sl <target> <name>	symlink
#   o md <name>			mkdir
#   o ch <name> <octal mode>	chmod
#   o wt | o wa <off> <len> <i>	truncate the WAL to 0 | write record i
#   f <name> <t0> <t1>		fsync of the file <name>
#   s <name> <t0> <t1>		fsync of the subdirectory <name>
#   a <i> <t0> <t1>		fsync of the directory, ending iteration i
#   wk <t0> <t1>		fsync of the WAL
#   err <errno> <ns>, bug <ns> <traceback>	the first error
# See act_nschurn.sh for what each kind of ack guarantees.
#
import collections
import errno
import hashlib
import os
import signal
import stat
import sys
import time
import traceback

W = 16			# a table lives W iterations
INIT = 40		# iterations setup runs on the healthy pool
SIZES = (0, 700, 20000, 65536, 135000)	# WR_NEED_COPY .. WR_INDIRECT
WREC = 4096		# WAL record
MAXHELD = 8		# unlinked tables held open
MARGIN = 1000000	# ns after spa_fail:entry (see act_nschurn.sh)
ACKS = ("a", "s", "f", "wk")


def data(tag, key, size):
	"""A file's content: each 4K block different."""
	seed = ("%s:%s:" % (tag, key)).encode()
	return b"".join(hashlib.sha256(seed + b"%d" % k).digest() * 128
	    for k in range((size + 4095) // 4096))[:size]


class Churn:
	def __init__(self, d, log, tag, mode):
		self.d = d
		self.tag = tag
		self.out = open(log, mode, buffering=1)
		self.held = []
		self.dfd = None
		self.wfd = None
		self.woff = 0

	def log(self, *a):
		self.out.write(" ".join(str(x) for x in a) + "\n")

	def p(self, name):
		return os.path.join(self.d, name)

	def fsync(self, fd, *what):
		t0 = time.monotonic_ns()
		os.fsync(fd)
		t1 = time.monotonic_ns()
		self.log(*(what + (t0, t1)))

	def write(self, fd, buf, off=None):
		n = 0
		while n < len(buf):
			if off is None:
				r = os.write(fd, buf[n:])
			else:
				r = os.pwrite(fd, buf[n:], off + n)
			if r <= 0:
				raise OSError(errno.EIO, "short write")
			n += r

	def newfile(self, name, key, size, sync):
		self.log("o", "c", name)
		fd = os.open(self.p(name), os.O_WRONLY | os.O_CREAT | os.O_EXCL,
		    0o644)
		self.log("o", "w", name, key, size)
		self.write(fd, data(self.tag, key, size))
		if sync:
			self.fsync(fd, "f", name)
		os.close(fd)

	def rename(self, a, b):
		self.log("o", "mv", a, b)
		os.rename(self.p(a), self.p(b))

	def unlink(self, name, op="rm"):
		self.log("o", op, name)
		os.unlink(self.p(name))

	def iteration(self, i):
		# Retire what iteration i - W made, as a compaction obsoletes
		# tables.  1 in 4 is unlinked while a reader still has it open:
		# it goes to the unlinked set, and its last close frees it.
		j = i - W
		if j >= 0:
			if j % 5 == 1:
				self.unlink("hl.%d" % j)
			if j % 6 == 2:
				self.unlink("sl.%d" % j)
			if j % 10 == 5:
				self.unlink("reg.%d/ext" % j)
				self.log("o", "rd", "reg.%d" % j)
				os.rmdir(self.p("reg.%d" % j))
			if j % 4 == 0:
				self.held.append(os.open(self.p("sst.%d" % j),
				    os.O_RDONLY))
				self.unlink("sst.%d" % j, "rmo")
			else:
				self.unlink("sst.%d" % j)
		# A new table, renamed into place.  1 in 3 isn't fsynced: the
		# rename commits its data (zil_itx_assign()).
		self.newfile("tmp.%d" % i, "%dt" % i, SIZES[i % len(SIZES)],
		    i % 3 != 2)
		self.rename("tmp.%d" % i, "sst.%d" % i)
		if i % 5 == 1:
			self.log("o", "ln", "sst.%d" % i, "hl.%d" % i)
			os.link(self.p("sst.%d" % i), self.p("hl.%d" % i))
		if i % 6 == 2:
			self.log("o", "sl", "sst.%d" % i, "sl.%d" % i)
			os.symlink("sst.%d" % i, self.p("sl.%d" % i))
		# Pebble's CURRENT: write a new one, fsync, rename it over.
		if i % 8 == 3:
			self.newfile("cur.%d" % i, "%dc" % i, 16 + i % 50, True)
			self.rename("cur.%d" % i, "CURRENT")
		# A setattr, committed by an fsync of the file.
		if i % 7 == 4 and i > 0:
			n = "sst.%d" % (i - 1)
			self.log("o", "ch", n, "600")
			os.chmod(self.p(n), 0o600)
			fd = os.open(self.p(n), os.O_RDONLY)
			self.fsync(fd, "f", n)
			os.close(fd)
		# Crucible's extent repair: fill a directory, fsync it, and
		# rename it into place.
		if i % 10 == 5:
			s = "stage.%d" % i
			self.log("o", "md", s)
			os.mkdir(self.p(s), 0o755)
			sfd = os.open(self.p(s), os.O_RDONLY)
			self.newfile(s + "/ext", "%de" % i, 12288 + i % 4096,
			    True)
			self.fsync(sfd, "s", s)
			os.close(sfd)
			self.rename(s, "reg.%d" % i)
		# The WAL: a record, or 1 in 16 a truncate (TX_TRUNCATE).
		if i % 16 == 15:
			self.log("o", "wt")
			os.ftruncate(self.wfd, 0)
			self.woff = 0
		else:
			self.log("o", "wa", self.woff, WREC, i)
			self.write(self.wfd, data(self.tag, "w%d" % i, WREC),
			    self.woff)
			self.woff += WREC
		self.fsync(self.wfd, "wk")
		self.fsync(self.dfd, "a", i)
		while len(self.held) > MAXHELD:
			os.close(self.held.pop(0))


def init(d, log, tag):
	os.umask(0o022)
	os.mkdir(d, 0o755)
	c = Churn(d, log, tag, "w")
	c.log("init", os.getpid(), time.monotonic_ns())
	c.dfd = os.open(d, os.O_RDONLY)
	c.log("o", "c", "wal")
	c.wfd = os.open(c.p("wal"), os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o644)
	for i in range(INIT):
		c.iteration(i)
	c.log("ready", INIT)
	return 0


def run(d, log, tag):
	os.umask(0o022)
	c = Churn(d, log, tag, "a")
	c.log("run", os.getpid(), time.monotonic_ns())
	try:
		c.dfd = os.open(d, os.O_RDONLY)
		c.wfd = os.open(c.p("wal"), os.O_RDWR)
		c.woff = os.fstat(c.wfd).st_size
		i = INIT
		while True:
			c.iteration(i)
			i += 1
	except OSError as e:
		c.log("err", e.errno, time.monotonic_ns())
	except Exception:
		c.log("bug", time.monotonic_ns(),
		    traceback.format_exc().replace("\n", " | "))
	# Hold the directory, the WAL, the unlinked tables and whatever was
	# open at the error, as a hung database would, until killed.
	while True:
		signal.pause()


#
# The verifier's model.
#
class Ino:
	def __init__(self, kind, target=None):
		self.kind = kind	# f(ile), w(al), d(irectory), l(ink)
		self.target = target	# a symlink's
		self.wkey = None	# (key, size) written
		self.key = None		# (key, size) acknowledged
		self.via = None		# by an fsync of the file, or a rename
		self.mode = 0o644	# the acknowledged mode
		self.modes = []		# modes tried since

	def describe(self):
		if self.kind == "d":
			return "a directory"
		if self.kind == "l":
			return "a symlink to %s" % self.target
		if self.kind == "w":
			return "the WAL"
		if self.key is None:
			return "a file"
		return "file %s (%d bytes, by %s)" % (self.key[0], self.key[1],
		    self.via)


def apply(ns, op, seen=None):
	"""Apply a namespace op to ns, {name: Ino}."""
	if op[0] == "set":
		ns[op[1]] = op[2]
		if seen is not None:
			seen.add(op[1])
	elif op[0] == "del":
		ns.pop(op[1], None)
	else:
		a, b = op[1], op[2]
		moved = {}
		for n in list(ns):
			if n == a or n.startswith(a + "/"):
				moved[b + n[len(a):]] = ns.pop(n)
		if moved:
			ns.pop(b, None)		# CURRENT's old inode
			ns.update(moved)
			if seen is not None:
				seen.update(moved)


def walapply(wal, w):
	if w[0] == "t":
		wal[0], wal[1] = 0, {}
	else:
		wal[1][w[1]] = (w[3], w[2])
		wal[0] = max(wal[0], w[1] + w[2])


class Model:
	def __init__(self, lines):
		self.ns = {}		# every op tried, applied
		self.seen = set()	# every name ever used
		self.ops = []		# the namespace ops
		self.nacked = 0		# how many a directory fsync covers
		self.renamed = []	# inodes renamed since then
		self.wal = [0, {}]	# acked size, {off: (i, len)}
		self.wpend = []		# WAL ops since its last fsync
		self.acks = []		# (kind, what, t0, t1)
		self.last = -1		# the last iteration acknowledged
		self.err = None
		for t in lines:
			self.step(t)

	def add(self, *op):
		self.ops.append(op)
		apply(self.ns, op, self.seen)

	def step(self, t):
		k = t[0]
		if k == "o":
			o, a = t[1], t[2:]
			if o == "c":
				self.add("set", a[0],
				    Ino("w" if a[0] == "wal" else "f"))
			elif o == "md":
				self.add("set", a[0], Ino("d"))
			elif o == "sl":
				self.add("set", a[1], Ino("l", a[0]))
			elif o == "ln":
				self.add("set", a[1], self.ns[a[0]])
			elif o in ("rm", "rmo", "rd"):
				self.add("del", a[0])
			elif o == "mv":
				self.renamed.append(self.ns[a[0]])
				self.add("mv", a[0], a[1])
			elif o == "w":
				self.ns[a[0]].wkey = (a[1], int(a[2]))
			elif o == "ch":
				self.ns[a[0]].modes.append(int(a[1], 8))
			elif o == "wt":
				self.wpend.append(("t",))
			elif o == "wa":
				self.wpend.append(("a", int(a[0]), int(a[1]),
				    int(a[2])))
		elif k in ("a", "s"):
			# Every namespace op so far is committed, and so is
			# the data of every file renamed since the last such
			# fsync, written before its rename.
			self.nacked = len(self.ops)
			for ino in self.renamed:
				if ino.key is None and ino.wkey is not None:
					ino.key, ino.via = ino.wkey, "rename"
			self.renamed = []
			if k == "a":
				self.last = int(t[1])
			self.acks.append((k, t[1], int(t[2]), int(t[3])))
		elif k == "f":
			# The file's writes and chmods are committed.
			ino = self.ns[t[1]]
			if ino.key is None and ino.wkey is not None:
				ino.key, ino.via = ino.wkey, "fsync"
			if ino.modes:
				ino.mode, ino.modes = ino.modes[-1], []
			self.acks.append((k, t[1], int(t[2]), int(t[3])))
		elif k == "wk":
			for w in self.wpend:
				walapply(self.wal, w)
			self.wpend = []
			self.acks.append((k, "", int(t[1]), int(t[2])))
		elif k in ("err", "bug") and self.err is None:
			self.err = "%s %s" % (k, t[1])


def parse(log, drop):
	"""The log's lines, without a torn last one, and without its last
	<drop> acks."""
	with open(log) as f:
		text = f.read()
	lines = [l.split() for l in text[:text.rfind("\n") + 1].splitlines()]
	lines = [t for t in lines if t]
	if drop:
		acks = [n for n, t in enumerate(lines) if t[0] in ACKS]
		gone = set(acks[-drop:])
		lines = [t for n, t in enumerate(lines) if n not in gone]
	return lines


def match(c, sb, path, tag, contents):
	"""None if what lstat found at path is candidate c, else why not."""
	ino, nlink = c
	if ino.kind == "d":
		return None if stat.S_ISDIR(sb.st_mode) else "not a directory"
	if ino.kind == "l":
		if not stat.S_ISLNK(sb.st_mode):
			return "not a symlink"
		t = os.readlink(path)
		if t != ino.target:
			return "a symlink to %s, not %s" % (t, ino.target)
		return None
	if not stat.S_ISREG(sb.st_mode):
		return "not a file (%s)" % ino.describe()
	if sb.st_nlink != nlink:
		return "%d links, not %d (%s)" % (sb.st_nlink, nlink,
		    ino.describe())
	modes = set([ino.mode] + ino.modes)
	if (sb.st_mode & 0o7777) not in modes:
		return "mode %o, not %s (%s)" % (sb.st_mode & 0o7777,
		    " or ".join("%o" % m for m in sorted(modes)), ino.describe())
	if ino.kind == "w" or ino.key is None:
		return None
	key, size = ino.key
	if sb.st_size != size:
		return "%d bytes, not %s" % (sb.st_size, ino.describe())
	if path not in contents:
		with open(path, "rb") as f:
			contents[path] = f.read()
	if contents[path] != data(tag, key, size):
		return "wrong content for %s" % ino.describe()
	return None


def listing(d):
	out = []
	for e in os.listdir(d):
		out.append(e)
		p = os.path.join(d, e)
		if stat.S_ISDIR(os.lstat(p).st_mode):
			out += [e + "/" + c for c in os.listdir(p)]
	return out


def check(d, log, tag, fail_ns, drop):
	"""Check one instance: (problems, summary, counts)."""
	m = Model(parse(log, drop))
	probs = []
	n = collections.Counter()

	late = [a for a in m.acks if fail_ns and a[2] > fail_ns + MARGIN]
	if late:
		k, what, t0, _ = late[0]
		probs.append("%s: %d fsyncs that started after the pool failed "
		    "returned 0 (first: %s %s, %.1f ms after spa_fail)" %
		    (tag, len(late), k, what, (t0 - fail_ns) / 1e6))

	# The acknowledged namespace, then one state per later op.
	st = {}
	for op in m.ops[:m.nacked]:
		apply(st, op)
	states = [dict(st)]
	for op in m.ops[m.nacked:]:
		apply(st, op)
		states.append(dict(st))
	links = [collections.Counter(s.values()) for s in states]
	pending = len(m.ops) - m.nacked

	if not os.path.isdir(d):
		probs.append("%s: %s is missing" % (tag, d))
		return probs, "%s: no directory" % tag, n

	contents = {}
	for name in sorted(m.seen):
		cands = set()
		for s, l in zip(states, links):
			ino = s.get(name)
			if ino is None:
				cands.add(None)
			elif ino.kind in ("f", "w"):
				cands.add((ino, l[ino]))
			else:
				cands.add((ino, None))
		if len(cands) > 1:
			n["either"] += 1
		path = os.path.join(d, name)
		try:
			sb = os.lstat(path)
		except OSError as e:
			if e.errno not in (errno.ENOENT, errno.ENOTDIR):
				probs.append("%s: %s: lstat: %s" %
				    (tag, name, e.strerror))
				continue
			sb = None
		if sb is None:
			if None not in cands:
				probs.append("%s: %s is missing; it should be "
				    "%s" % (tag, name, " or ".join(
				    c[0].describe() for c in cands)))
			elif len(cands) == 1:
				n["absent"] += 1
			continue
		if cands == {None}:
			probs.append("%s: %s is there, but its removal (or "
			    "rename) was acknowledged" % (tag, name))
			continue
		why = []
		for c in cands:
			if c is None:
				continue
			try:
				r = match(c, sb, path, tag, contents)
			except OSError as e:
				r = "%s" % e.strerror
			if r is None:
				n["present"] += 1
				if c[0].kind == "f" and c[0].key is not None:
					n["content"] += 1
					if c[0].via == "rename":
						n["renamed"] += 1
				break
			why.append(r)
		else:
			probs.append("%s: %s: %s" % (tag, name, "; ".join(why)))

	try:
		for name in listing(d):
			if name not in m.seen:
				probs.append("%s: %s is there, but was never "
				    "created" % (tag, name))
	except OSError as e:
		probs.append("%s: listing %s: %s" % (tag, d, e.strerror))

	# The WAL.  A pending truncate could have landed, and the records
	# after it are then anyone's guess.  Otherwise its size is one it had
	# at an op boundary: a pending 4K append is all there or not at all
	# (zil_replay_split(); see act_nschurn.sh).
	wal = "-"
	if any(w[0] == "t" for w in m.wpend):
		wal = "truncate pending"
	else:
		size, recs = m.wal
		sizes = [size]
		for w in m.wpend:
			sizes.append(max(sizes[-1], w[1] + w[2]))
		try:
			fd = os.open(os.path.join(d, "wal"), os.O_RDONLY)
		except OSError as e:
			fd = None
			if e.errno != errno.ENOENT:	# reported above
				probs.append("%s: wal: %s" % (tag, e.strerror))
		if fd is not None:
			try:
				got = os.fstat(fd).st_size
				if got not in sizes:
					probs.append("%s: wal is %d bytes, not "
					    "%s" % (tag, got, " or ".join(
					    str(z) for z in sorted(set(sizes)))))
				bad = [i for off, (i, ln) in sorted(recs.items())
				    if os.pread(fd, ln, off) !=
				    data(tag, "w%d" % i, ln)]
				if bad:
					probs.append("%s: wal: %d acknowledged "
					    "records are wrong (first %s)" %
					    (tag, len(bad), bad[:5]))
				n["wal"] = len(recs)
				wal = "%d records" % len(recs)
			except OSError as e:
				probs.append("%s: wal: %s" % (tag, e.strerror))
			finally:
				os.close(fd)

	cur = states[0].get("CURRENT")
	summary = ("%s: iteration %d acked, %d ops pending%s; %d present, "
	    "%d absent, %d either; %d contents (%d by rename); CURRENT %s; "
	    "wal %s" % (tag, m.last, pending,
	    ", " + m.err if m.err else "", n["present"], n["absent"],
	    n["either"], n["content"], n["renamed"],
	    cur.key[0] if cur is not None and cur.key else "-", wal))
	return probs, summary, n


def instances(args):
	return [args[k:k + 3] for k in range(0, len(args) - 2, 3)]


def selfcheck(args):
	"""On the healthy pool after init: everything logged is there.  With
	the last acks ignored, the real state is one of the later ones."""
	sums = []
	for drop in (0, 1, 2, 3, 4):
		for d, log, tag in instances(args):
			probs, s, n = check(d, log, tag, 0, drop)
			if drop == 0 and not probs:
				if n["either"]:
					probs.append("%s: %d names ambiguous with "
					    "every op acknowledged" %
					    (tag, n["either"]))
				if not (n["present"] and n["absent"] and
				    n["content"] and n["wal"]):
					probs.append("%s: checked nothing: %s" %
					    (tag, s))
				sums.append(s)
			if probs:
				for p in probs:
					print("drop %d: %s" % (drop, p))
				print("nschurn self-check FAILED (last %d acks "
				    "ignored): %s" % (drop, probs[0]))
				return 1
	print("nschurn self-check ok: %s" % "; ".join(sums))
	return 0


def verify(fail_ns, args):
	probs, sums, bug = [], [], False
	for d, log, tag in instances(args):
		try:
			p, s, _ = check(d, log, tag, fail_ns, 0)
		except Exception:
			# A bug here, not in the pool: say so, don't fail.
			traceback.print_exc(file=sys.stdout)
			s = "%s: verifier error %r" % (tag, sys.exc_info()[1])
			p, bug = [], True
		probs += p
		sums.append(s)
	for p in probs:
		print(p)
	for s in sums:
		print(s)
	if probs:
		print("nschurn FAILED: %s%s" % (probs[0], " (+%d more)" %
		    (len(probs) - 1) if len(probs) > 1 else ""))
		return 3	# act_nschurn_verify: a failure, not a bug here
	print("nschurn %s: %s" % ("NOT ALL CHECKED" if bug else "ok",
	    "; ".join(sums)))
	return 0


def main():
	cmd, args = sys.argv[1], sys.argv[2:]
	if cmd == "init":
		return init(*args)
	if cmd == "run":
		run(*args)
	if cmd == "selfcheck":
		return selfcheck(args)
	if cmd == "verify":
		return verify(int(args[0]), args[1:])
	return 2


sys.exit(main())
NSCHURN_PY_EOF
}
