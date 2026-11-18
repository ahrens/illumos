#
# act_dwell.sh: chaos activity "dwell", sourced by chaos.sh.
#
# Oxide's sled-agent doesn't export a failed U.2 pool right away.  It stops
# managing the disk and shuts down the zones that use it, so the pool stays
# FAILED and imported for minutes while its users exit.  chaos exports soon
# after the failure, so this module can only emulate the users' side of that
# window, between the failure and the export:
#
# - Three "zone-like" holders, each with its cwd, open files and mappings in
#   the pool, and a SIGTERM handler that lets go of them (fsync, msync,
#   munmap, close, chdir /) and exits, as a zone's processes do when the
#   zone is halted:
#     z0  a zone root, $POOL/crypt/zone/oxz_dwell0 (encrypted, like Oxide's
#         zone roots): a log it appends to (and fsyncs on SIGTERM), a file
#         it reads, a library-like MAP_PRIVATE mapping, and a MAP_SHARED
#         mapping it dirtied and leaves dirty (zfs_inactive() drops the
#         pages it can't write).
#     z1  a Crucible-like downstairs, $POOL/dwell/region (unencrypted, like
#         oxp_*/crucible): extent files it writes and fsyncs (and fsyncs
#         again on SIGTERM), a dirty MAP_SHARED "region.db" it msyncs on
#         SIGTERM, and a file it unlinks while holding it open, so that its
#         close runs zfs_rmnode() on the failed pool.
#     z2  a Propolis-like process, cwd $POOL/crypt/zone/oxz_dwell2, with a
#         bootrom mapping and the volume $POOL/dwellvol, which it reads and
#         writes (synchronously, as the volume's write cache is off), so that
#         its close is the volume's last close on a failed pool
#         (zvol_close()'s txg wait, zil_close() of a failed log).
# - A teardown (a stream) that polls the pool's spa_exit with mdb until the
#   pool has failed (2), or is gone (exported by -F before the teardown saw
#   it fail), then sends SIGTERM to the zone holders one at a time, in a
#   random order, with a short delay, and logs how long each took to exit.
#   Each SIGTERM follows the previous holder's exit, or 0.5 s, whichever
#   comes first, so that a slow holder doesn't hold up the rest; the
#   teardown then waits for the stragglers, each until 10 s after its own
#   SIGTERM.
#
# The export follows the failure, but not at once: the harness first waits
# for every writer to get an error (writers_errored, up to 20 s), which gives
# the teardown time to run before the export, and the export of a failed pool
# itself takes a while.  So most SIGTERMs land on the failed, still imported
# pool; a SIGTERM sent after the export is logged as such (by whether the
# mounts are still in mnttab, which "zpool export" removes at its end), and
# the 10 s rule applies to it too.  The harness kills the holders only after
# the streams are gone, so the teardown never races its kill -9.
#
# The harness wants the streams gone within 15 s of the export, and the
# export can finish before the teardown sees the failure (trigger F).  So
# the teardown is done 13 s after its last poll that found the pool still
# there (when it saw it failed, or the poll before it saw it gone): at most
# 1 s waiting for the holders to be set up, about 1.5 s sending the
# SIGTERMs, and 10 s for the last one.  A holder still exiting at 13 s (a
# slow mdb, or a starved teardown) is logged as unfinished, not hung, and
# left to the harness's kill -9.
#
# Verify: every zone holder that got a SIGTERM was gone 10 s later, and the
# datasets setup created exist (their creates returned 0 before the pool
# failed, so they are in a synced txg).  "Gone" means that its last lwp has
# reached proc_exit() (psinfo's pr_nlwp is 0) or it has been reaped: the
# holders aren't the teardown's children, so it can't wait for them, and
# proc_exit() drops pr_nlwp before it closes files and frees the address
# space, so the handlers let go of everything in the pool themselves first.
# A holder that dies before its SIGTERM (say SIGBUS from a mapping that
# faulted on the failed pool) is reported, not failed.  Nothing else is
# checked: z1's fsyncs are acknowledged writes, but the harness's writers
# check durability.
#
# Files in $DIR: act_dwell.py (the helpers, written by setup), act_dwell.zvol
# (the volume z2 uses), act_dwell.z[012].log (each holder's events),
# act_dwell.td.log (the teardown's), act_dwell.stack.<name> (the kernel
# stacks of a holder that didn't exit), act_dwell.out (the helpers' stderr).
#

# act_dwell_fill <file> <128k blocks>: fill with random data
function act_dwell_fill
{
	dd if=/dev/urandom of=$1 bs=128k count=$2 2>/dev/null
}

function act_dwell_setup
{
	typeset r0=/$POOL/crypt/zone/oxz_dwell0 r2=/$POOL/crypt/zone/oxz_dwell2
	typeset rg=/$POOL/dwell/region zv=/dev/zvol/rdsk/$POOL/dwellvol
	typeset -i n

	rm -f $DIR/act_dwell.*
	if ! act_dwell_py > $DIR/act_dwell.py; then
		print "dwell: setup: can't write $DIR/act_dwell.py"
		return 1
	fi
	if ! zfs create $POOL/crypt/zone/oxz_dwell0 ||
	    ! zfs create $POOL/crypt/zone/oxz_dwell2 ||
	    ! zfs create -o compression=off $POOL/dwell ||
	    ! zfs create -o volblocksize=8k -V 16m $POOL/dwellvol; then
		print "dwell: setup: zfs create failed"
		return 1
	fi
	# Everything the holders open exists already: they never create a
	# file, in case they start after an export -F, when the mountpoints
	# are bare directories that the next iteration's mounts need empty.
	if ! mkdir -p $r0/etc $r0/var $r0/lib $rg ||
	    ! touch $r0/var/svc.log $r2/propolis.log ||
	    ! act_dwell_fill $r0/etc/conf 1 ||
	    ! act_dwell_fill $r0/lib/libfake.so 8 ||
	    ! mkfile 1m $r0/var/shm ||
	    ! act_dwell_fill $r2/bootrom 4 ||
	    ! act_dwell_fill $rg/ext0 16 ||
	    ! act_dwell_fill $rg/ext1 16 ||
	    ! act_dwell_fill $rg/ext2 16 ||
	    ! act_dwell_fill $rg/region.db 2 ||
	    ! act_dwell_fill $rg/tmp.unl 16; then
		print "dwell: setup: can't populate the datasets"
		return 1
	fi
	n=6
	until [[ -c $zv ]]; do
		((n-- == 0)) && break
		sleep 0.5
	done
	# z2 reads the first 2 MB and writes the next 2 MB.  Without the
	# minor, z2 runs without a volume rather than stop the run.
	if [[ -c $zv ]]; then
		if ! act_dwell_fill $zv 16; then
			print "dwell: setup: can't write $zv"
			return 1
		fi
		print -r -- $zv > $DIR/act_dwell.zvol
	else
		print -r -- "" > $DIR/act_dwell.zvol
	fi
	return 0
}

function act_dwell_start
{
	typeset py=$DIR/act_dwell.py zv pids

	zv=$(< $DIR/act_dwell.zvol)
	holder python3 $py zone root z0 $DIR/act_dwell.z0.log \
	    /$POOL/crypt/zone/oxz_dwell0 >> $DIR/act_dwell.out 2>&1
	pids="z0=$!"
	holder python3 $py zone crucible z1 $DIR/act_dwell.z1.log \
	    /$POOL/dwell/region >> $DIR/act_dwell.out 2>&1
	pids="$pids z1=$!"
	holder python3 $py zone propolis z2 $DIR/act_dwell.z2.log \
	    /$POOL/crypt/zone/oxz_dwell2 $zv >> $DIR/act_dwell.out 2>&1
	pids="$pids z2=$!"
	stream python3 $py teardown $POOL $DIR $it $pids \
	    >> $DIR/act_dwell.out 2>&1
}

function act_dwell_verify
{
	# A create that returned 0 is in a synced txg.
	if ! zfs list -H -o name $POOL/crypt/zone/oxz_dwell0 \
	    $POOL/crypt/zone/oxz_dwell2 $POOL/dwell $POOL/dwellvol \
	    > /dev/null 2>&1; then
		print "dwell: DATASETS CREATED BEFORE THE FAILURE ARE GONE:" \
		    "$(zfs list -H -o name -r $POOL 2>&1 | egrep 'dwell' | paste -s -d' ' -)"
		return 1
	fi
	python3 $DIR/act_dwell.py verify $DIR
}

# act_dwell_py: print the helpers (setup writes them to $DIR/act_dwell.py)
function act_dwell_py
{
	cat <<'EOF'
#
# act_dwell.py: the processes of chaos's "dwell" activity (see act_dwell.sh).
#
#   zone <kind> <name> <log> <root> [<volume>]
#	A zone-like holder of kind root, crucible or propolis.  It logs
#	"pid", "ready" once it holds everything, the first error of each kind
#	of operation, and on SIGTERM "term", any errors letting go, and
#	"released" just before it exits.
#   teardown <pool> <dir> <iter> <name>=<pid>...
#	Wait for the pool to fail, then SIGTERM each holder in turn and wait
#	up to 10 s for it to exit.  Logs "detected <state> <ns> mdb-misses
#	<n> since <t_low>", then per holder "term <name> <pid> <mounted>
#	<t0> <t1>", "hung <name> <pid> <mounted> <t0> <ps state>",
#	"unfinished <name> <pid> <mounted> <t0> <ns>" (still exiting when
#	the teardown had to stop) or "dead <name> <pid> <ns>" (gone before
#	its SIGTERM), and "done <ns>".
#   verify <dir>
#	Print one line about the teardown; exit 1 if a holder was still there
#	10 s after its SIGTERM.
#
# Times are time.monotonic_ns(), which is gethrtime() (DTrace's timestamp)
# on illumos.
#
import mmap
import os
import random
import resource
import signal
import struct
import subprocess
import sys
import time

TERM_LIMIT_NS = 10 * 10**9	# a holder must be gone this long after SIGTERM
READY_WAIT_NS = 2 * 10**9	# from the start, for the holders to be set up,
READY_MAX_NS = 1 * 10**9	# ... but no longer than this after the failure
NEXT_NS = 5 * 10**8		# SIGTERM the next holder by then at the latest
STOP_NS = 13 * 10**9		# done this long after t_low (see teardown_impl)
GIVE_UP_NS = 240 * 10**9	# the harness fails an iteration well before this
SPA_EXIT_FAILED = 2
MDB_CMD = '::walk spa | ::printf "%s %d\\n" spa_t spa_name spa_exit\n'


def now():
	return time.monotonic_ns()


class Log:
	# os.write, not a buffered file: the SIGTERM handler logs too, and it
	# may run in the middle of another write.
	def __init__(self, path):
		self.fd = os.open(path,
		    os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_APPEND, 0o644)

	def line(self, s):
		try:
			os.write(self.fd, (s + "\n").encode())
		except OSError:
			pass

	def ev(self, s):
		self.line("%s %d" % (s, now()))


def zone(kind, name, logpath, root, vol=None):
	log = Log(logpath)
	fds, syncs, maps = [], [], []
	seen = set()
	rng = random.Random(os.getpid())

	def on_term(sig, frame):
		signal.signal(signal.SIGTERM, signal.SIG_IGN)
		log.ev("term")
		for fd in syncs:
			try:
				os.fsync(fd)
			except OSError as e:
				log.ev("release-err fsync %d" % e.errno)
		for m, msync in maps:
			try:
				if msync:
					m.flush()
			except OSError as e:
				log.ev("release-err msync %d" % e.errno)
			except Exception as e:
				log.ev("release-err msync %s" % type(e).__name__)
			try:
				m.close()
			except Exception as e:
				log.ev("release-err munmap %s" % type(e).__name__)
		for fd in fds:
			try:
				os.close(fd)
			except OSError as e:
				log.ev("release-err close %d" % e.errno)
		try:
			os.chdir("/")
		except OSError:
			pass
		log.ev("released")
		os._exit(0)

	signal.signal(signal.SIGTERM, on_term)
	log.line("pid %d" % os.getpid())
	try:
		resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
	except (ValueError, OSError):
		pass

	def step(what, fn, *a):
		try:
			return fn(*a)
		except OSError as e:
			log.ev("setup-err %s %d" % (what, e.errno))
		except Exception as e:
			log.ev("setup-err %s %s" % (what, type(e).__name__))
		return None

	def op(what, fn, *a):
		try:
			fn(*a)
		except OSError as e:
			if what not in seen:
				seen.add(what)
				log.ev("err %s %d" % (what, e.errno))

	# Never O_CREAT: see act_dwell_setup.
	def openf(path, flags, sync=False):
		fd = step("open " + path, os.open, path, flags)
		if fd is not None:
			fds.append(fd)
			if sync:
				syncs.append(fd)
		return fd

	def mapf(path, shared, msync=False):
		fd = openf(path, os.O_RDWR if shared else os.O_RDONLY)
		if fd is None:
			return

		def domap():
			if shared:
				m = mmap.mmap(fd, 0, flags=mmap.MAP_SHARED,
				    prot=mmap.PROT_READ | mmap.PROT_WRITE)
			else:
				m = mmap.mmap(fd, 0, flags=mmap.MAP_PRIVATE,
				    prot=mmap.PROT_READ)
			maps.append((m, msync))
			# Touch every page now, while the file is cached, and
			# never again: a fault that has to read a failed pool
			# gets SIGBUS.  (The pool can fail before this runs;
			# then a page that isn't cached kills the holder, which
			# the teardown reports as gone before its SIGTERM.)
			for off in range(0, len(m), mmap.PAGESIZE):
				if shared:
					m[off] = (m[off] + 1) % 256
				else:
					m[off]
		step("mmap " + path, domap)

	step("chdir", os.chdir, root)
	p = lambda f: os.path.join(root, f)
	if kind == "root":
		lf = openf(p("var/svc.log"), os.O_WRONLY | os.O_APPEND, sync=True)
		cf = openf(p("etc/conf"), os.O_RDONLY)
		mapf(p("lib/libfake.so"), shared=False)
		mapf(p("var/shm"), shared=True)

		def tick(i):
			if lf is not None and i % 2 == 0:
				op("append", os.write, lf, b"tick %d\n" % i)
			if cf is not None:
				op("read", os.pread, cf, 4096,
				    rng.randrange(32) * 4096)
			return 0.05
	elif kind == "crucible":
		ext = [openf(p("ext%d" % j), os.O_RDWR, sync=True)
		    for j in range(3)]
		mapf(p("region.db"), shared=True, msync=True)
		uf = openf(p("tmp.unl"), os.O_RDWR)
		if uf is not None:
			step("unlink", os.unlink, p("tmp.unl"))

		def tick(i):
			fd = ext[i % 3]
			if fd is not None:
				op("write", os.pwrite, fd,
				    bytes([i % 256]) * 4096,
				    rng.randrange(512) * 4096)
				if i % 5 == 0:
					op("fsync", os.fsync, fd)
			if uf is not None and i % 3 == 0:
				op("read-unlinked", os.pread, uf, 4096,
				    rng.randrange(512) * 4096)
			return 0.03
	else:
		mapf(p("bootrom"), shared=False)
		lf = openf(p("propolis.log"), os.O_WRONLY | os.O_APPEND)
		zf = openf(vol, os.O_RDWR) if vol else None
		if zf is None:
			log.ev("novolume")

		def tick(i):
			if zf is not None:
				op("vol-read", os.pread, zf, 8192,
				    rng.randrange(256) * 8192)
				if i % 4 == 0:
					op("vol-write", os.pwrite, zf,
					    bytes([i % 256]) * 8192,
					    (256 + rng.randrange(256)) * 8192)
			if lf is not None and i % 10 == 0:
				op("append", os.write, lf, b"vcpu %d\n" % i)
			return 0.02
	log.ev("ready")
	i = 0
	while True:
		i += 1
		try:
			delay = tick(i)
		except Exception as e:
			# Never exit on our own: we are a holder.
			log.ev("exception %s" % type(e).__name__)
			delay = 1
		time.sleep(delay)


def pool_exit(pool):
	# spa_exit of the pool, "gone" if it isn't loaded, None if mdb failed
	try:
		r = subprocess.run(["mdb", "-k"], input=MDB_CMD,
		    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
		    universal_newlines=True, timeout=3)
	except (subprocess.SubprocessError, OSError):
		return None
	pools = {}
	for line in r.stdout.splitlines():
		f = line.split()
		if len(f) == 2 and f[1].isdigit():
			pools[f[0]] = int(f[1])
	# The healthy pool is always there, so no pools means mdb failed.
	if not pools:
		return None
	return pools.get(pool, "gone")


def mounted(special):
	try:
		with open("/etc/mnttab") as f:
			for line in f:
				if line.split("\t", 1)[0] == special:
					return True
	except OSError:
		pass
	return False


def exited(pid):
	# The process's last lwp has gone into proc_exit(), or the process has
	# been reaped.  Its parent is the harness's shell, so we can't wait for
	# it, and kill(pid, 0) succeeds until the shell reaps it.  psinfo's
	# pr_nlwp (psinfo_t starts with pr_flag, pr_nlwp, pr_pid) drops to 0
	# before proc_exit() closes the files and frees the address space,
	# which is why the holders let go of the pool's files themselves.
	try:
		with open("/proc/%d/psinfo" % pid, "rb") as f:
			b = f.read(12)
	except FileNotFoundError:
		return True
	except OSError:
		try:
			os.kill(pid, 0)
		except ProcessLookupError:
			return True
		except OSError:
			pass
		return False
	if len(b) < 12:
		return False
	_, nlwp, pr_pid = struct.unpack("=iii", b)
	return pr_pid != pid or nlwp == 0


def ps_state(pid):
	# ps's view, to double-check exited() before reporting a hang:
	# "" if the process is gone, "Z" if it is a zombie
	try:
		r = subprocess.run(["ps", "-o", "s=", "-p", str(pid)],
		    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
		    universal_newlines=True, timeout=2)
	except (subprocess.SubprocessError, OSError):
		return "?"
	s = r.stdout.split()
	if len(s) > 1:
		return "?"
	return s[0] if s else ""


def ready(d, name):
	try:
		with open("%s/act_dwell.%s.log" % (d, name)) as f:
			return any(l.startswith("ready ") for l in f)
	except OSError:
		return False


def stacks(d, name, pid):
	# In the background, so that the teardown exits on time: the harness
	# wants the streams gone within 15 s of the export.
	cmd = ("echo '0t%d::pid2proc | ::walk thread | ::findstack -v' | "
	    "mdb -k > %s/act_dwell.stack.%s 2>&1" % (pid, d, name))
	try:
		subprocess.Popen(["/bin/sh", "-c", cmd],
		    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
		    stderr=subprocess.DEVNULL, start_new_session=True)
	except OSError:
		pass


def teardown(pool, d, it, pairs):
	log = Log(d + "/act_dwell.td.log")
	try:
		teardown_impl(log, pool, d, it, pairs)
	except Exception as e:
		log.line("error %s %s" % (type(e).__name__, e))
	log.ev("done")


def teardown_impl(log, pool, d, it, pairs):
	holders = []
	for pair in pairs:
		n, _, pid = pair.partition("=")
		holders.append((n, int(pid)))
	special = pool + "/dwell"
	rng = random.Random(it)
	t_start = now()
	log.line("start %d %s" % (t_start,
	    " ".join("%s=%d" % h for h in holders)))

	# t_low: a time before the export finished.  The pool was still
	# there when the poll that started at t_poll saw it failed, and when
	# the previous one, which started at t_prev, saw it not failed, or
	# (with mdb not working) saw the mounts.  The harness's 15 s for the
	# streams start when the export finishes, so stop by t_low + STOP_NS
	# however slow mdb is.
	misses = 0
	t_poll = t_start
	while True:
		t_prev, t_poll = t_poll, now()
		st = pool_exit(pool)
		if st == SPA_EXIT_FAILED:
			state, t_low = "failed", t_poll
			break
		if st == "gone":
			state, t_low = "gone", t_prev
			break
		if st is None:
			misses += 1
			# mdb isn't working: go once the export has removed
			# the mounts.
			if not mounted(special):
				state, t_low = "unmounted", t_prev
				break
		if now() - t_start > GIVE_UP_NS:
			log.line("giveup %d mdb-misses %d" % (now(), misses))
			return
		time.sleep(0.2)
	t_det = now()
	log.line("detected %s %d mdb-misses %d since %d" % (state, t_det,
	    misses, t_low))
	stop = t_low + STOP_NS

	# The holders started with us, and are normally set up long before
	# the pool fails; one that isn't by now may never be (see mapf()).
	ready_by = min(t_start + READY_WAIT_NS, t_det + READY_MAX_NS)
	while now() < ready_by and not all(ready(d, n) for n, _ in holders):
		time.sleep(0.05)
	time.sleep(rng.uniform(0, 0.1))
	order = list(holders)
	rng.shuffle(order)
	slow = []
	for i, (n, pid) in enumerate(order):
		if i > 0:
			time.sleep(rng.uniform(0.05, 0.2))
		if exited(pid):
			log.line("dead %s %d %d" % (n, pid, now()))
			continue
		mnt = int(mounted(special))
		t0 = now()
		try:
			os.kill(pid, signal.SIGTERM)
		except ProcessLookupError:
			log.line("dead %s %d %d" % (n, pid, t0))
			continue
		slow += settle(log, d, [(n, pid, mnt, t0)], t0 + NEXT_NS, stop)
	settle(log, d, slow, None, stop)


def settle(log, d, waiting, until, stop):
	# Poll the holders in waiting, each (name, pid, mounted, t0 of its
	# SIGTERM), and log each one's fate as it is settled: it exited, it
	# was still there TERM_LIMIT_NS after its SIGTERM (hung), or the
	# teardown had to stop first (unfinished).  Gives up at until (None:
	# never) and returns those not settled by then.
	waiting = list(waiting)
	while waiting:
		for h in list(waiting):
			n, pid, mnt, t0 = h
			t = now()
			if exited(pid):
				log.line("term %s %d %d %d %d" % (n, pid, mnt, t0,
				    now()))
			elif t - t0 >= TERM_LIMIT_NS:
				ps = ps_state(pid)
				if ps in ("", "Z"):
					log.line("term %s %d %d %d %d" % (n, pid,
					    mnt, t0, now()))
				else:
					log.line("hung %s %d %d %d %s" % (n, pid,
					    mnt, t0, ps))
					stacks(d, n, pid)
			elif t >= stop:
				log.line("unfinished %s %d %d %d %d" % (n, pid,
				    mnt, t0, t))
			else:
				continue
			waiting.remove(h)
		if not waiting or (until is not None and now() >= until):
			break
		time.sleep(0.02)
	return waiting


def holder_log(d, name):
	try:
		with open("%s/act_dwell.%s.log" % (d, name)) as f:
			return f.read().splitlines()
	except OSError:
		return []


def handler_ms(lines):
	# from the SIGTERM handler's start to its letting go of everything
	t = {}
	for l in lines:
		f = l.split()
		if f and f[0] in ("term", "released") and f[-1].isdigit():
			t[f[0]] = int(f[-1])
	if len(t) < 2:
		return None
	return (t["released"] - t["term"]) // 10**6


def verify(d):
	try:
		with open(d + "/act_dwell.td.log") as f:
			lines = f.read().splitlines()
	except OSError:
		print("dwell: no teardown log, nothing checked")
		return 0
	state, t_det = None, None
	terms, hung, unfin, dead, notes = [], [], [], [], []
	done = False
	# Each line was one write(2), so it is whole.  Still, a line that
	# doesn't parse is noted rather than allowed to crash the verifier,
	# whose traceback would stop the run; a "hung" one fails regardless.
	for l in lines:
		f = l.split()
		if not f:
			continue
		try:
			if f[0] == "detected":
				state, t_det = f[1], int(f[2])
			elif f[0] == "term":
				terms.append((f[1], int(f[2]), int(f[3]),
				    int(f[4]), int(f[5])))
			elif f[0] == "hung":
				hung.append((f[1], int(f[2]), int(f[3]),
				    int(f[4]), f[5]))
			elif f[0] == "unfinished":
				unfin.append((f[1], (int(f[5]) - int(f[4])) /
				    1e9))
			elif f[0] == "dead":
				dead.append(f[1])
			elif f[0] in ("error", "giveup"):
				notes.append(l)
			elif f[0] == "done":
				done = True
		except (IndexError, ValueError):
			if f[0] == "hung":
				hung.append(l)
			else:
				notes.append("unparsed '%s'" % l)

	if hung:
		why = []
		for h in hung:
			try:
				n, pid, mnt, t0, ps = h
				hl = holder_log(d, n)
				ran = any(x.startswith("term ") for x in hl)
				why.append("%s pid %d (ps %s) sent %s after the "
				    "pool was seen %s, %s; its handler %s; its "
				    "log ends '%s'" % (n, pid, ps,
				    "%.1f s" % ((t0 - t_det) / 1e9)
				    if t_det is not None else "?", state,
				    "while mounted" if mnt else "after the export",
				    "started" if ran else "never ran",
				    hl[-1] if hl else ""))
			except Exception:
				why.append(str(h))
		print("dwell: ZONE HOLDER NOT GONE 10 s AFTER SIGTERM: %s "
		    "(stacks in act_dwell.stack.*)" % "; ".join(why))
		return 1

	try:
		print(summary(d, state, t_det, terms, unfin, dead, notes, done))
	except Exception as e:
		print("dwell: no holder hung (summary failed: %s %s)" %
		    (type(e).__name__, e))
	return 0


def summary(d, state, t_det, terms, unfin, dead, notes, done):
	if not terms:
		s = "dwell: no SIGTERM sent"
		if state is None:
			s += " (the teardown never saw the pool fail)"
	else:
		s = "dwell: pool %s; exits after SIGTERM: %s; %d of %d sent " \
		    "while mounted, the first %d ms after it was seen" % (state,
		    ", ".join("%s %d ms" % (t[0], (t[4] - t[3]) // 10**6)
		    for t in terms), sum(t[2] for t in terms), len(terms),
		    (min(t[3] for t in terms) - t_det) // 10**6)
		hms = [handler_ms(holder_log(d, t[0])) for t in terms]
		hms = [x for x in hms if x is not None]
		if hms:
			s += "; handlers max %d ms" % max(hms)
	if unfin:
		s += "; still exiting when the teardown stopped: %s" % \
		    ", ".join("%s %.1f s" % u for u in unfin)
	if dead:
		s += "; gone before SIGTERM: %s" % " ".join(dead)
	if any("novolume" in l for l in holder_log(d, "z2")):
		s += "; z2 had no volume"
	if notes:
		s += "; " + "; ".join(notes)
	if not done:
		s += "; teardown log incomplete"
	return s

if __name__ == "__main__":
	cmd = sys.argv[1]
	if cmd == "zone":
		zone(*sys.argv[2:7])
	elif cmd == "teardown":
		teardown(sys.argv[2], sys.argv[3], int(sys.argv[4]),
		    sys.argv[5:])
	elif cmd == "verify":
		sys.exit(verify(sys.argv[2]))
	else:
		sys.exit(2)
EOF
}
