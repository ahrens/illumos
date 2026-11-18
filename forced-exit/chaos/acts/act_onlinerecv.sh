#
# act_onlinerecv.sh: chaos activity "onlinerecv", sourced by chaos.sh.
#
# Online incremental receives and rollbacks into a mounted file system while
# a process sits in it.  At setup, $OK/orsrc gets a chain of snapshots
# @or1..@or10 (each version adds a 2 MB file, overwrites, appends to,
# truncates, renames and removes others; small files are lz4-compressible or
# embedded), and @or1 is received into $POOL/online, mounted.  The workload:
# - a stream loops "zfs send [-e] [-c] -i @orK-1 @orK | [throttle] |
#   zfs recv -s -F $POOL/online", and now and then "zfs rollback" to the
#   newest snapshot or "zfs rollback -r" to an older one, until a command
#   fails, logging each command before it starts and its rc after;
# - a holder has its cwd in /$POOL/online, keeps files open across the
#   receives and rollbacks (so zfs_resume_fs() re-gets their znodes), holds
#   a file in the automounted .zfs/snapshot/or1, and checks every chunk it
#   reads against the versions of that file.
# So the pool fails with the file system suspended (receive or rollback
# between zfs_suspend_fs() and zfs_resume_fs()), in a receive's data phase,
# or in a sync task's txg wait.
#
# After the import, verify checks:
# - $POOL/online exists and mounts;
# - every snapshot that an acknowledged (rc 0) op left must be there, and none
#   that an acknowledged op removed (or that was never received) may be;
#   only the last op, the one the failure interrupted, may go either way;
# - every snapshot has its source's guid;
# - the head's tree is exactly the source version that the log allows, and
#   is consistent with the snapshots (a receive's snapshot and clone swap
#   are one sync task, and a rollback lands only after the destroys);
# - no op that began after spa_fail (DTrace timestamp in d.out) returned 0;
# - a resume token, if there is one, resumes from $OK (and the result
#   matches its source) or "zfs recv -A" removes it cleanly;
# - the holder never read bytes that no version of the file has.
#
# Its helper program is embedded below and written to $DIR at setup.
#

ACT_ONLINERECV_N=10	# snapshots in the chain: @or1..@or10

function act_onlinerecv_setup
{
	typeset b=$DIR/act_onlinerecv msg
	typeset -i rc
	rm -f $b.log $b.err $b.reader $b.manifest $b.build
	if ! act_onlinerecv_py > $b.py; then
		print -r -- "onlinerecv: cannot write $b.py"
		return 1
	fi
	# atime=off: reading the source back for the manifest must not change it.
	if ! zfs create -o compression=lz4 -o atime=off $OK/orsrc > $b.build 2>&1; then
		print -r -- "onlinerecv: zfs create $OK/orsrc failed: $(head -1 $b.build)"
		return 1
	fi
	# python3 -I: $DIR, the script's directory, is not searched for
	# modules, so no other file there can shadow one of the stdlib's.
	msg=$(python3 -I $b.py build $OK/orsrc $ACT_ONLINERECV_N $b.manifest \
	    $POOL/online $b.build 2>&1)
	rc=$?
	if ((rc != 0)); then
		print -r -- "onlinerecv: setup failed: ${msg##*$'\n'}"
		return 1
	fi
	return 0
}

function act_onlinerecv_start
{
	typeset b=$DIR/act_onlinerecv
	# The reader first, so that it is in place when the first receive
	# suspends the file system.
	holder python3 -I $b.py reader $b.manifest $b.reader
	stream python3 -I $b.py loop $POOL/online $OK/orsrc $ACT_ONLINERECV_N \
	    $b.log $b.err $H/throttle.py $it
}

function act_onlinerecv_verify
{
	typeset b=$DIR/act_onlinerecv out
	typeset -i rc
	out=$(python3 -I $b.py verify $POOL/online $b.manifest $b.log $b.err \
	    $b.reader $DIR/d.out 2>>$b.err)
	rc=$?
	# Only the helper's own verdict stops the run.  A helper that didn't
	# get to one (missing, or killed by an uncaught error, which also
	# exits 1) is a bug here, not in the pool.
	if ((rc == 1)) && [[ $out == "onlinerecv: FAILED: "* ]]; then
		print -r -- "$out"
		return 1
	fi
	if ((rc == 0)) && [[ $out == "onlinerecv: "* ]]; then
		print -r -- "$out"
		return 0
	fi
	print -r -- "onlinerecv: INCONCLUSIVE: helper exited $rc: ${out##*$'\n'} (stderr in $b.err)"
	return 0
}

function act_onlinerecv_py
{
	cat <<'ONLINERECV_PY_EOF'
#
# act_onlinerecv.py: helper of chaos's onlinerecv activity.  Generated from
# acts/act_onlinerecv.sh at every setup; edit it there.
#
#   build <src> <n> <manifest> <dst> <outlog>
#	Make <src>@or1..@or<n>, record each version's tree in <manifest>, and
#	receive @or1 into <dst> (mounted).  Prints one line on failure.
#   loop <dst> <src> <n> <log> <errlog> <throttle.py> <seed>
#	Receive the next incremental, or roll back, until a command fails.
#	<log> gets "S <seq> <op> <arg> <cur> <how> <t0>" before each command
#	and "E <seq> <rc> <t1> <rcs>" after it, where op is R (receive @or<arg>
#	on top of @or<cur>), B (rollback -r to @or<arg>) or T (rollback to the
#	newest, @or<cur>).  Times are time.monotonic_ns(), i.e. gethrtime().
#   reader <manifest> <log>
#	Sit in <dst>'s mountpoint and read its files, checking each chunk
#	read against the versions; logs "BAD"/"ZERO"/"cross" lines and stats.
#   verify <dst> <manifest> <log> <errlog> <readerlog> <d.out>
#	Check the re-imported <dst>; print one line; exit 1 on a failure.
#
import hashlib
import json
import os
import random
import signal
import stat
import subprocess
import sys
import time

CH = 32768		# the unit the manifest and the reader check


def digest(b):
	return hashlib.blake2b(b, digest_size=8).hexdigest()


def sn(k):
	return "or%d" % k


def sh(args, timeout=120):
	"""Run a command; return (rc, stdout, stderr)."""
	try:
		p = subprocess.run(args, stdout=subprocess.PIPE,
		    stderr=subprocess.PIPE, timeout=timeout)
	except subprocess.TimeoutExpired:
		return 124, "", "%s: timed out after %d s" % (args[0], timeout)
	except OSError as e:
		return 127, "", "%s: %s" % (args[0], e)
	return (p.returncode, p.stdout.decode("utf-8", "replace"),
	    p.stderr.decode("utf-8", "replace"))


def first(s):
	s = s.strip()
	return s.splitlines()[0] if s else ""


def start(cmds, out):
	"""Start cmds as a pipeline: stdin from /dev/null, every stderr and the
	last stdout to out.  We keep no pipe ends, so that SIGPIPE/EPIPE gets
	through when a command exits."""
	procs = []
	prev = subprocess.DEVNULL
	try:
		for i, c in enumerate(cmds):
			last = i == len(cmds) - 1
			p = subprocess.Popen(c, stdin=prev,
			    stdout=out if last else subprocess.PIPE, stderr=out)
			procs.append(p)
			if prev is not subprocess.DEVNULL:
				prev.close()
			prev = p.stdout
	except OSError:
		if prev is not subprocess.DEVNULL and prev is not None:
			prev.close()
		for p in procs:
			p.kill()
			p.wait()
		raise
	return procs


def finish(procs, timeout=None):
	"""Wait for a pipeline; return each command's rc, or None if it was
	killed at the timeout."""
	end = None if timeout is None else time.monotonic() + timeout
	rcs = []
	for p in reversed(procs):
		try:
			left = None if end is None else \
			    max(0.1, end - time.monotonic())
			rcs.append(p.wait(left))
		except subprocess.TimeoutExpired:
			for q in procs:
				q.kill()
			for q in procs:
				q.wait()
			return None
	return list(reversed(rcs))


def put(path, data, off=None):
	"""Write data at off, or replace the file's contents."""
	flags = os.O_WRONLY | os.O_CREAT
	if off is None:
		flags |= os.O_TRUNC
		off = 0
	fd = os.open(path, flags, 0o644)
	try:
		v = memoryview(data)
		while v:
			n = os.pwrite(fd, v, off)
			v = v[n:]
			off += n
	finally:
		os.close(fd)


def text(k, n):
	line = ("version %d of the online receive chain\n" % k).encode()
	return (line * (n // len(line) + 1))[:n]


def version(mnt, k):
	"""Turn the tree at mnt into version k.  Each name keeps one object
	for its whole life (in-place changes, renames, and no name created
	twice), which the reader's per-name check relies on."""
	def p(name):
		return os.path.join(mnt, name)
	if k == 1:
		put(p("base0"), os.urandom(1 << 20))
		put(p("base1"), text(1, 256 << 10))
		put(p("trunc"), os.urandom(320 << 10))
		put(p("log"), b"v1\n")
		os.mkdir(p("d"))
		put(p("d/a"), text(1, 100))
		put(p("d/b"), text(1, 50 << 10))
		os.symlink("base1", p("lnk"))
		put(p("tiny1"), text(1, 300))
		return
	# Creates first, so no object freed in this version is reused by it.
	put(p("f%d" % k), os.urandom(2 << 20))
	put(p("tiny%d" % k), text(k, 300))
	put(p("base0"), os.urandom(128 << 10), (k << 17) % (1 << 20))
	put(p("log"), b"v%d\n" % k, os.path.getsize(p("log")))
	os.chmod(p("log"), 0o600 if k % 2 else 0o644)
	if k % 2 == 0:
		os.truncate(p("trunc"), 64 << 10)
	else:
		put(p("trunc"), os.urandom(256 << 10), 64 << 10)
	put(p("d/a"), text(k, 100 + k))
	if k >= 3:
		os.unlink(p("tiny%d" % (k - 2)))
	if k >= 4:
		os.rename(p("f%d" % (k - 2)), p("g%d" % (k - 2)))
	if k >= 6:
		os.unlink(p("g%d" % (k - 4)))


def entry(path):
	st = os.lstat(path)
	if stat.S_ISLNK(st.st_mode):
		return {"t": "l", "l": os.readlink(path)}
	if stat.S_ISDIR(st.st_mode):
		return {"t": "d", "m": st.st_mode & 0o7777}
	with open(path, "rb") as f:
		data = f.read()
	return {"t": "f", "s": len(data), "m": st.st_mode & 0o7777,
	    "c": [digest(data[i:i + CH]) for i in range(0, len(data), CH)]}


def tree(root):
	"""Map each path under root (but .zfs) to its entry.  Raises OSError
	if a directory can't be read."""
	out = {}

	def onerror(e):
		raise e
	for dirpath, dirnames, filenames in os.walk(root, onerror=onerror):
		dirnames[:] = [d for d in dirnames if d != ".zfs"]
		for name in dirnames + filenames:
			full = os.path.join(dirpath, name)
			out[os.path.relpath(full, root)] = entry(full)
	return out


class Fail(Exception):
	pass


def build(src, n, manifest, dst, outlog):
	log = open(outlog, "a", buffering=1)
	rc, mnt, err = sh(["zfs", "get", "-H", "-o", "value", "mountpoint",
	    src])
	if rc != 0:
		raise Fail("zfs get mountpoint %s: %s" % (src, first(err)))
	mnt = mnt.strip()
	vers = {}
	recv = None
	try:
		for k in range(1, n + 1):
			version(mnt, k)
			rc, _, err = sh(["zfs", "snapshot", "%s@%s" % (src, sn(k))])
			if rc != 0:
				raise Fail("zfs snapshot %s@%s: %s" %
				    (src, sn(k), first(err)))
			vers[str(k)] = tree(mnt)
			if k == 1:
				# Receive @or1 while the rest of the chain is built.
				recv = start([["zfs", "send", "%s@%s" % (src, sn(1))],
				    ["zfs", "recv", dst]], log)
		rcs = finish(recv, 120)
		recv = None
	finally:
		if recv is not None:
			finish(recv, 1)
	if rcs is None or rcs[-1] != 0:
		raise Fail("zfs send %s@%s | zfs recv %s: rcs %s (see %s)" %
		    (src, sn(1), dst, rcs, outlog))
	# illumos zfs takes no options after the property list.
	rc, out, err = sh(["zfs", "get", "-H", "-p", "-o", "name,value", "-t",
	    "snapshot", "-r", "guid", src])
	guids = {}
	for line in out.splitlines():
		f = line.split("\t")
		if len(f) == 2 and "@" in f[0]:
			name = f[0].split("@", 1)[1]
			if name.startswith("or") and name[2:].isdigit():
				guids[name[2:]] = f[1]
	if rc != 0 or sorted(guids) != sorted(vers):
		raise Fail("snapshot guids of %s: %s" % (src, first(err)))
	rc, out, err = sh(["zfs", "get", "-H", "-o", "value",
	    "mounted,mountpoint", dst])
	f = out.split()
	if rc == 0 and len(f) == 2 and f[0] != "yes":
		sh(["zfs", "mount", dst])
		rc, out, err = sh(["zfs", "get", "-H", "-o", "value",
		    "mounted,mountpoint", dst])
		f = out.split()
	if rc != 0 or len(f) != 2 or f[0] != "yes":
		raise Fail("%s is not mounted: %s" % (dst, first(err) or out))
	tmp = manifest + ".tmp"
	with open(tmp, "w") as o:
		json.dump({"n": n, "src": src, "dst": dst, "mnt": f[1],
		    "guids": guids, "versions": vers}, o)
	os.rename(tmp, manifest)


def loop(dst, src, n, log, errlog, throttle, seed):
	out = open(log, "w", buffering=1)
	err = open(errlog, "a", buffering=1)
	out.write("pid %d\n" % os.getpid())
	rng = random.Random(seed)
	cur, seq = 1, 0
	end = time.monotonic() + 600	# a safety net; failures stop it first
	while time.monotonic() < end:
		r = rng.random()
		if cur >= n or (cur > 1 and r < 0.15):
			op, arg, how = "B", rng.randint(1, cur - 1), "r"
			cmds = [["zfs", "rollback", "-r",
			    "%s@%s" % (dst, sn(arg))]]
		elif r < 0.27:
			op, arg, how = "T", cur, "-"
			cmds = [["zfs", "rollback", "%s@%s" % (dst, sn(cur))]]
		else:
			op, arg = "R", cur + 1
			flags = rng.choice([[], ["-e"], ["-c"], ["-e", "-c"]])
			how = "".join(x[1] for x in flags) or "p"
			cmds = [["zfs", "send"] + flags + ["-i",
			    "%s@%s" % (src, sn(cur)), "%s@%s" % (src, sn(arg))]]
			if rng.random() < 0.3:
				# 3 MB/s: the failure may land in the data phase.
				cmds.append(["python3", throttle, "3"])
				how += "t"
			cmds.append(["zfs", "recv", "-s", "-F", dst])
		err.write("== %d %s %d %s\n" % (seq, op, arg, how))
		out.write("S %d %s %d %d %s %d\n" %
		    (seq, op, arg, cur, how, time.monotonic_ns()))
		try:
			rcs = finish(start(cmds, err))
		except OSError as e:
			err.write("%s\n" % e)
			rcs = [127]
		out.write("E %d %d %d %s\n" % (seq, rcs[-1], time.monotonic_ns(),
		    ",".join(str(x) for x in rcs)))
		if rcs[-1] != 0:
			break
		cur = arg
		seq += 1
	out.write("stop %d\n" % time.monotonic_ns())


def reader(manifest, log):
	out = open(log, "w", buffering=1)
	out.write("pid %d\n" % os.getpid())
	m = json.load(open(manifest))
	# allowed[path][chunk]: what that chunk of that name holds in any
	# version.  A read is atomic with respect to the receive's or
	# rollback's swap (zfs_read() holds z_teardown_lock as reader
	# throughout), and a failed pool fails a read of anything uncached
	# with EIO (spa_exit.c, "only syncing context sees poisoned blocks"),
	# so every chunk read that succeeds must be one of these.
	allowed, links = {}, {}
	for t in m["versions"].values():
		for path, e in t.items():
			if e["t"] == "f":
				a = allowed.setdefault(path, {})
				for i, d in enumerate(e["c"]):
					a.setdefault(i, set()).add(d)
			elif e["t"] == "l":
				links.setdefault(path, set()).add(e["l"])
	anyd = {}
	for a in allowed.values():
		for i, s in a.items():
			anyd.setdefault(i, set()).update(s)
	snapc = m["versions"]["1"]["base0"]["c"]
	rng = random.Random(os.getpid())
	st = {"passes": 0, "reads": 0, "errors": 0, "bad": 0, "cross": 0}
	seen = set()
	logged = [0]

	def error(e, what):
		st["errors"] += 1
		if e.errno not in seen:
			seen.add(e.errno)
			out.write("errno %d %s %d\n" %
			    (e.errno, what, time.monotonic_ns()))

	def report(kind, what, d):
		st["cross" if kind == "cross" else "bad"] += 1
		if logged[0] < 20:
			logged[0] += 1
			out.write("%s %s %s %d\n" %
			    (kind, what, d, time.monotonic_ns()))

	def check(fd, path, want=None):
		if want is None and path not in allowed:
			return
		size = os.fstat(fd).st_size
		if size == 0:
			return
		i = rng.randrange((size + CH - 1) // CH)
		b = os.pread(fd, CH, i * CH)
		if not b:
			return		# the file shrank since the fstat()
		st["reads"] += 1
		d = digest(b)
		if want is not None:
			if i < len(want) and want[i] == d:
				return
		elif d in allowed[path].get(i, ()):
			return
		if b.count(0) == len(b):
			kind = "ZERO"
		elif want is None and d in anyd.get(i, ()):
			# Another file's data: names keep their objects, and
			# zfs_rezget() fails a znode whose object was reused
			# (z_gen), so this shouldn't happen, but it rests on
			# that reasoning: verify only notes it.
			kind = "cross"
		else:
			kind = "BAD"
		report(kind, "%s:%d:%d" % (path, i, len(b)), d)

	try:
		os.chdir(m["mnt"])
	except OSError as e:
		error(e, "chdir")
		while True:
			signal.pause()
	# Kept open for the whole run, across every receive and rollback.
	longfds = []
	for name in ("base0", "trunc", "log", "d/a"):
		try:
			longfds.append((os.open(name, os.O_RDONLY), name))
		except OSError as e:
			error(e, "open " + name)
	snapfd = None
	held = []
	last = 0.0
	while True:
		st["passes"] += 1
		if snapfd is None and st["passes"] % 10 == 1:
			try:
				snapfd = os.open(".zfs/snapshot/or1/base0",
				    os.O_RDONLY)
			except OSError as e:
				error(e, "open or1/base0")
		if snapfd is not None:
			try:
				check(snapfd, "@or1/base0", snapc)
			except OSError as e:
				error(e, "read @or1/base0")
		for fd, path in longfds + held:
			try:
				check(fd, path)
			except OSError as e:
				error(e, "read " + path)
		names = []
		try:
			names = os.listdir(".")
		except OSError as e:
			error(e, "readdir")
		if "d" in names:
			try:
				names += ["d/" + x for x in os.listdir("d")]
			except OSError as e:
				error(e, "readdir d")
		new = []
		for path in names:
			try:
				mode = os.lstat(path).st_mode
				if stat.S_ISDIR(mode):
					continue
				if stat.S_ISLNK(mode):
					t = os.readlink(path)
					if path in links and t not in links[path]:
						report("BAD", "symlink:" + path, t)
					continue
				fd = os.open(path, os.O_RDONLY)
			except OSError as e:
				error(e, "open " + path)
				continue
			new.append((fd, path))
			try:
				check(fd, path)
			except OSError as e:
				error(e, "read " + path)
		for fd, _ in held:
			try:
				os.close(fd)
			except OSError:
				pass
		held = new
		if st["passes"] % 10 == 0:
			try:
				os.listdir(".zfs/snapshot")
			except OSError as e:
				error(e, "readdir .zfs/snapshot")
		now = time.monotonic()
		if now - last >= 0.5:
			last = now
			out.write("stat %d %d %d %d %d %d\n" % (st["passes"],
			    st["reads"], st["errors"], st["bad"], st["cross"],
			    time.monotonic_ns()))
		time.sleep(0.02)


def parse_log(path):
	ops, order = {}, []
	try:
		lines = open(path).read().splitlines()
	except OSError:
		return None
	for line in lines:
		f = line.split()
		try:
			if len(f) == 7 and f[0] == "S":
				s = int(f[1])
				ops[s] = {"seq": s, "op": f[2], "arg": int(f[3]),
				    "cur": int(f[4]), "how": f[5], "t0": int(f[6]),
				    "rc": None, "t1": None}
				order.append(s)
			elif len(f) >= 4 and f[0] == "E" and int(f[1]) in ops:
				ops[int(f[1])]["rc"] = int(f[2])
				ops[int(f[1])]["t1"] = int(f[3])
		except ValueError:
			pass
	return [ops[s] for s in order]


def fail_time(dout):
	"""The harness's failure time: the first spa_fail line of d.out."""
	try:
		with open(dout) as f:
			for line in f:
				if line.startswith("spa_fail "):
					return int(line.split()[1])
	except (OSError, ValueError, IndexError):
		pass
	return None


def opname(o):
	return "%s%d" % (o["op"], o["arg"])


def snaplist(ks):
	ks = sorted(ks)
	if not ks:
		return "none"
	if ks == list(range(ks[0], ks[-1] + 1)) and len(ks) > 2:
		return "or%d-or%d" % (ks[0], ks[-1])
	return ",".join(sn(k) for k in ks)


def snaps(dst):
	"""The chain's snapshots on dst, {k: guid}; ignores other names (other
	activities may snapshot recursively)."""
	rc, out, err = sh(["zfs", "list", "-H", "-p", "-o", "name,guid", "-t",
	    "snapshot", "-d", "1", dst], 60)
	if rc != 0:
		raise Fail("zfs list snapshots of %s: %s" % (dst, first(err)))
	got = {}
	for line in out.splitlines():
		f = line.split("\t")
		if len(f) != 2 or "@" not in f[0]:
			continue
		name = f[0].split("@", 1)[1]
		if name.startswith("or") and name[2:].isdigit():
			got[int(name[2:])] = int(f[1])
	return got


def props(dst):
	rc, out, err = sh(["zfs", "get", "-H", "-o", "property,value",
	    "mounted,mountpoint,receive_resume_token", dst], 60)
	if rc != 0:
		return None, first(err)
	p = {}
	for line in out.splitlines():
		f = line.split("\t")
		if len(f) == 2:
			p[f[0]] = f[1]
	return p, ""


def diff(a, b):
	"""Paths whose entries differ between trees a and b (a few)."""
	d = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
	return ",".join(d[:4]) + (",..." if len(d) > 4 else "")


def resume(tok, dst, errlog):
	"""Resume dst's interrupted receive from the source; (ok, message)."""
	with open(errlog, "a", buffering=1) as err:
		err.write("== verify resume\n")
		pos = err.tell()
		try:
			rcs = finish(start([["zfs", "send", "-t", tok],
			    ["zfs", "recv", "-s", "-F", dst]], err), 60)
		except OSError as e:
			return False, str(e)
	if rcs is not None and rcs[-1] == 0:
		return True, ""
	msg = ""
	try:
		with open(errlog) as f:
			f.seek(pos)
			msg = first(f.read())
	except OSError:
		pass
	return False, "rcs %s: %s" % (rcs, msg)


def verify(dst, manifest, log, errlog, rlog, dout):
	m = json.load(open(manifest))
	vers = {int(k): v for k, v in m["versions"].items()}
	guids = {int(k): int(g) for k, g in m["guids"].items()}
	mnt = m["mnt"]
	bad, notes = [], []

	# What the log says.  The loop stops at the first command that
	# fails, so every op but the last returned 0, and only the last can
	# be in doubt: its txg may have committed even if it returned an
	# error, or the stream may have been cut short in it.
	ops = parse_log(log)
	if ops is None:
		notes.append("no loop log")
		ops = []
	if any(o["rc"] != 0 for o in ops[:-1]):
		print("onlinerecv: INCONCLUSIVE: an op after a failed one in %s"
		    % log)
		return 0
	acked = [o for o in ops if o["rc"] == 0]
	x = ops[-1] if ops and ops[-1]["rc"] != 0 else None
	a = acked[-1]["arg"] if acked else 1	# newest after acked ops
	if x is not None and x["cur"] != a:
		print("onlinerecv: INCONCLUSIVE: op %d starts from @or%d, not "
		    "@or%d" % (x["seq"], x["cur"], a))
		return 0
	must = set(range(1, a + 1))
	may = set(must)
	heads = {a}
	if x is not None and x["op"] == "R":
		may.add(x["arg"])
		heads.add(x["arg"])
	elif x is not None and x["op"] == "B":
		# libzfs destroys the later snapshots one sync task at a time,
		# in ZAP order, before the rollback: any subset may be gone.
		must = set(range(1, x["arg"] + 1))
		heads.add(x["arg"])
	counts = {}
	for o in ops:
		counts[o["op"]] = counts.get(o["op"], 0) + 1
	summary = ["%d ops (%s)" % (len(ops), " ".join("%s%d" % (k, counts[k])
	    for k in sorted(counts))), "acked @or%d" % a]
	fail_ns = fail_time(dout)
	if x is not None:
		s = "in doubt %s rc %s" % (opname(x), x["rc"])
		if fail_ns is not None:
			dt = (x["t0"] - fail_ns) / 1e6
			s += " (began %d ms %s the failure)" % (abs(dt),
			    "after" if dt > 0 else "before")
			if x["t1"] is not None and x["t1"] < fail_ns:
				notes.append("loop stopped before the failure")
		summary.append(s)

	# A sync task whose txg was drained returns EIO, and a txg that
	# opens after spa_fail() is always drained: a command that began
	# after it can't succeed (as verify.py afterfail for writes).
	if fail_ns is not None:
		late = [o for o in acked if o["t0"] > fail_ns]
		if late:
			bad.append("%s began %d ms after the failure but returned 0"
			    % (opname(late[0]), (late[0]["t0"] - fail_ns) // 1000000))

	# The dataset was made by a receive that returned 0 at setup.
	p, err = props(dst)
	if p is None:
		bad.append("%s missing after import: %s" % (dst, err))
		print("onlinerecv: FAILED: %s; %s" % ("; ".join(bad),
		    ", ".join(summary)))
		return 1
	mounted = p.get("mounted") == "yes"
	if not mounted:
		rc, _, merr = sh(["zfs", "mount", dst], 60)
		p2, _ = props(dst)
		mounted = p2 is not None and p2.get("mounted") == "yes"
		if mounted:
			notes.append("mounted only by a second zfs mount")
		else:
			bad.append("%s does not mount: %s" % (dst, first(merr)))
	if p.get("mountpoint") not in (None, mnt):
		mnt = p["mountpoint"]

	P = snaps(dst)
	summary.append("snaps %s" % snaplist(P))
	missing = sorted(must - set(P))
	if missing:
		bad.append("acknowledged snapshot(s) %s missing" %
		    snaplist(missing))
	extra = sorted(set(P) - may)
	if extra:
		bad.append("snapshot(s) %s present though an acknowledged "
		    "rollback destroyed them" % snaplist(extra))
	wrong = sorted(k for k in P if k in guids and P[k] != guids[k])
	if wrong:
		bad.append("snapshot(s) %s have the wrong guid" % snaplist(wrong))

	h = None
	if mounted:
		try:
			head = tree(mnt)
		except OSError as e:
			head = None
			bad.append("reading the head: %s" % e)
		if head is not None:
			for k in sorted(vers):
				if vers[k] == head:
					h = k
					break
			if h is None:
				bad.append("head matches no version (differs "
				    "from @or%d in %s)" % (a, diff(head, vers[a])))
			elif h not in heads:
				bad.append("head is @or%d, but the log allows "
				    "only %s" % (h, snaplist(heads)))
			elif x is not None and x["op"] == "R" and \
			    (x["arg"] in P) != (h == x["arg"]):
				# dmu_recv_end_sync() makes the snapshot and
				# swaps the head in one sync task.
				bad.append("receive of @or%d half there: "
				    "snapshot %s, head @or%d" % (x["arg"],
				    "present" if x["arg"] in P else "absent", h))
			elif x is not None and x["op"] == "B" and \
			    h == x["arg"] and any(k > h for k in P):
				# The rollback's sync task checks that its
				# target is the newest snapshot, so the
				# destroys before it are on disk if it is.
				bad.append("head rolled back to @or%d, but %s "
				    "remain" % (h, snaplist(k for k in P if k > h)))
			if h is not None:
				summary.append("head @or%d" % h)

	tok = p.get("receive_resume_token", "-")
	if tok not in ("-", ""):
		if x is None or x["op"] != "R":
			notes.append("token without a receive in doubt")
		ok, msg = resume(tok, dst, errlog)
		if ok:
			P2 = snaps(dst)
			new = sorted(set(P2) - set(P))
			p3, _ = props(dst)
			if len(new) != 1:
				bad.append("resumed receive made snapshots %s" %
				    snaplist(new))
			else:
				k = new[0]
				summary.append("token resumed @or%d" % k)
				if x is not None and x["op"] == "R" and \
				    k != x["arg"]:
					notes.append("resumed @or%d, but R%d was "
					    "in doubt" % (k, x["arg"]))
				if k in guids and P2[k] != guids[k]:
					bad.append("resumed @or%d has the wrong "
					    "guid" % k)
				if mounted:
					try:
						h2 = tree(mnt)
						if h2 != vers.get(k):
							bad.append("resumed @or%d "
							    "differs from its source "
							    "in %s" % (k,
							    diff(h2, vers.get(k, {}))))
					except OSError as e:
						bad.append("reading the head after "
						    "the resume: %s" % e)
			if p3 is not None and \
			    p3.get("receive_resume_token") not in ("-", ""):
				bad.append("a token remains after the resumed "
				    "receive finished")
		else:
			rc, _, aerr = sh(["zfs", "recv", "-A", dst], 60)
			p3, _ = props(dst)
			if rc != 0 or p3 is None or \
			    p3.get("receive_resume_token") not in ("-", ""):
				bad.append("resume token neither usable (%s) nor "
				    "abortable (%s)" % (msg, first(aerr) or
				    "token remains"))
			else:
				summary.append("token aborted (resume: %s)" % msg)
	else:
		summary.append("no token")

	# What the reader saw while the pool failed.
	rstat, rbad, rerr = None, [], []
	try:
		rlines = open(rlog).read().splitlines()
	except OSError:
		rlines = []
		notes.append("no reader log")
	for line in rlines:
		f = line.split()
		if not f:
			continue
		if f[0] in ("BAD", "ZERO"):
			rbad.append(" ".join(f[:3]))
		elif f[0] == "stat" and len(f) >= 6:
			try:
				rstat = [int(v) for v in f[1:6]]
			except ValueError:
				pass
		elif f[0] == "errno" and len(f) >= 2:
			rerr.append(f[1])
	if rstat is not None:
		summary.append("reader %d passes %d reads %d errors%s" %
		    (rstat[0], rstat[1], rstat[2],
		    " (errno %s)" % ",".join(rerr) if rerr else ""))
		if rstat[4]:
			notes.append("reader saw %d chunks of other files" %
			    rstat[4])
	if rbad:
		bad.append("reader read data no version has: %s (%d such)" %
		    (rbad[0], max(len(rbad), rstat[3] if rstat else 0)))

	line = ", ".join(summary)
	if notes:
		line += "; " + "; ".join(notes)
	if bad:
		print("onlinerecv: FAILED: %s; %s" % ("; ".join(bad), line))
		return 1
	print("onlinerecv: ok: %s" % line)
	return 0


def main(argv):
	cmd = argv[1]
	if cmd == "build":
		try:
			build(argv[2], int(argv[3]), argv[4], argv[5], argv[6])
		except (Fail, OSError) as e:
			print("onlinerecv build: %s" % e)
			return 1
		return 0
	if cmd == "loop":
		loop(argv[2], argv[3], int(argv[4]), argv[5], argv[6], argv[7],
		    int(argv[8]))
		return 0
	if cmd == "reader":
		reader(argv[2], argv[3])
		return 0
	if cmd == "verify":
		try:
			return verify(argv[2], argv[3], argv[4], argv[5], argv[6],
			    argv[7])
		except Fail as e:
			print("onlinerecv: FAILED: %s" % e)
			return 1
		except Exception as e:
			# A bug here, not in the pool: don't stop the run.
			print("onlinerecv: INCONCLUSIVE: verify raised %s: %s" %
			    (type(e).__name__, e))
			return 0
	return 2


if __name__ == "__main__":
	sys.exit(main(sys.argv))
ONLINERECV_PY_EOF
}
