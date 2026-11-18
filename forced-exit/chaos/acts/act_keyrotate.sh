#
# act_keyrotate.sh: chaos activity "keyrotate", sourced by chaos.sh.
#
# Encryption key churn on the crypt hierarchy that setup() builds
# ($POOL/crypt: aes-256-gcm, keyformat=raw, keylocation=file://$DIR/key;
# child $POOL/crypt/zone with the w2 writer), the way omicron rotates its
# crypt keys, while the pool fails:
#
# - rotate: zfs change-key -o keylocation=file://<keys>/kN -o oxide:epoch=N
#   $POOL/crypt, N = 1, 2, ..., each kN a new 32-byte raw key written first
#   and kept.  Epoch 0 is the harness's own key ($DIR/key), recorded by
#   setup.  Each change-key rewraps the DSL crypto keys of crypt and every
#   child that inherits from it (crypt/zone, with its writer running) and
#   sets keylocation and oxide:epoch, all in one sync task
#   (spa_keystore_change_key_sync()).
# - churn: encryption roots created and destroyed under crypt
#   ($POOL/crypt/krI, its own raw key <keys>/rI).  At random, a root is
#   mounted (with its mountpoint under $DIR, so that a mount that races the
#   export creates nothing under /$POOL) and gets an fsync'd file, or is
#   created canmount=off; and it is made to inherit crypt's key
#   (zfs change-key -i) before it is destroyed.
# Both loops log every command before and after it runs ("A ..." and the
# result, with time.monotonic_ns() times, which are DTrace's timestamp), and
# stop at their first error, so that they exit by themselves once the pool
# fails.
#
# verify, after the import, zfs load-key -r $POOL/crypt and zfs mount -a:
# - crypt's oxide:epoch E is at least the last epoch whose change-key
#   returned 0 and at most the last one tried; its keylocation is epoch E's
#   key file (change-key sets both in the same sync task), that file exists,
#   the harness's load-key left the key available, and epoch E's key
#   decrypts it (zfs load-key -n -L).  If the key isn't available, it says
#   which kept key does decrypt it.  A load that fails because the property
#   and the key went out of sync is a failure.
# - crypt and crypt/zone are mounted (so their DSL crypto keys unwrap with
#   the epoch-E key: a child rewrapped in a different txg than its root
#   wouldn't mount).
# - every krI: a create that returned 0 and was never destroyed is there; a
#   destroy that returned 0 is not; one that is there has the encryption
#   root that its change-key -i says (crypt if it returned 0, itself if it
#   wasn't tried).  If it is its own root, its keylocation names its key
#   file and load-key -r loaded it, or, only if its create didn't return 0,
#   its keylocation is none and its key still decrypts it (see below).  If
#   its key is loaded it mounts, and a file whose fsync returned 0 is there
#   with what was written.
# - no change-key, create, destroy or fsync that started after the pool
#   failed (spa_fail in $DIR/d.out) returned 0.
# It prints one line; details (including why each loop stopped, and any
# command that failed before the pool did) go to $DIR/act_keyrotate.verify,
# and on a failure the logs are copied to $DIR/act_keyrotate.fail.$it.
#
# Limits: the epoch, keylocation and key are checked together on crypt
# only; nothing here changes crypt/zone's own encryption root, keyformat or
# passphrase keys, or encrypted zvols and raw sends.  There is no crypt=
# DTrace bucket (chaos.d belongs to the harness).  The "started after the
# failure" checks need chaos.d's spa_fail line and are skipped without it.
#
# Subtle rules the checks depend on (also noted where they are used):
# - zfs_ioc_create() creates a dataset and its DSL crypto key in one sync
#   task, but sets the properties given with it (keylocation, canmount,
#   mountpoint, user properties) in a later one ("It would be nice to do
#   this atomically").  So a root whose create returned an error can come
#   back with keylocation=none: its key can't load from the property, and
#   that is accepted, but its own key must still decrypt it.  Omicron creates
#   crypt this way too (keylocation and oxide:epoch as create properties),
#   so a pool that fails right after creating crypt can come back without
#   them.
# - zfs destroy returns 0 when the destroy ioctl fails with ENOENT
#   (zfs_destroy()), which it does when the export removed the pool after
#   zfs_open().  A destroy counts as returning 0 only if the pool was still
#   imported after it ("zpool list" succeeded).
# - Nothing is written through a krI path unless the descriptor is on the
#   mounted root (st_dev differs from its parent directory), so a write
#   that loses a race with the export's unmount fails instead of landing in
#   the directory under the mount point (which would then keep the root from
#   mounting after the import).
#

function act_keyrotate_setup
{
	typeset k=$DIR/act_keyrotate kl

	[[ -n $DIR && -n $POOL ]] || { print "keyrotate: DIR or POOL unset"; return 1; }
	rm -rf $k.keys
	rm -f $k.py $k.rot $k.churn $k.verify $k.out
	# The last iteration's mount points: a root mounted there now would be
	# one that the last pool's destroy left behind.
	if mount -p | nawk -v m=$k.mnt '$3 == m || index($3, m "/") == 1 {
	    f = 1 } END { exit !f }'; then
		print "keyrotate: something is still mounted under $k.mnt"
		return 1
	fi
	rm -rf $k.mnt
	if ! mkdir -p $k.keys $k.mnt; then
		print "keyrotate: cannot create $k.keys and $k.mnt"
		return 1
	fi
	if ! act_keyrotate_helper > $k.py; then
		print "keyrotate: cannot write $k.py"
		return 1
	fi
	kl=$(zfs get -H -o value keylocation $POOL/crypt 2>&1)
	if [[ $kl != "file://$DIR/key" ]]; then
		print "keyrotate: $POOL/crypt has keylocation $kl, not file://$DIR/key"
		return 1
	fi
	if ! zfs set oxide:epoch=0 $POOL/crypt > $k.out 2>&1; then
		print "keyrotate: zfs set oxide:epoch=0 $POOL/crypt failed: $(head -1 $k.out)"
		return 1
	fi
	return 0
}

function act_keyrotate_start
{
	typeset k=$DIR/act_keyrotate

	# Each loop sends its own output to $k.out.
	stream python3 $k.py rotate $POOL $DIR
	stream python3 $k.py churn $POOL $DIR ${it:-0}
	return 0
}

function act_keyrotate_verify
{
	typeset k=$DIR/act_keyrotate line
	typeset -i rc

	if [[ ! -f $k.py ]]; then
		print "keyrotate: $k.py is missing (setup did not run)"
		return 1
	fi
	line=$(python3 $k.py verify $POOL $DIR ${it:-0} 2>> $k.out)
	rc=$?
	[[ -z $line ]] && line="keyrotate: verify printed nothing (rc $rc, see $k.out)"
	print -r -- "$line"
	return $rc
}

# act_keyrotate_helper: print the python helper (setup writes it to $DIR)
function act_keyrotate_helper
{
	cat <<'EOF'
#
# act_keyrotate.py: helper for chaos's keyrotate activity (act_keyrotate.sh
# writes it at setup).
#
#   rotate <pool> <dir>		change-key loop on <pool>/crypt
#   churn <pool> <dir> <seed>	encryption-root create/inherit/destroy loop
#   verify <pool> <dir> <iter>	check the re-imported pool against the logs
#
# The loops log "A <tag> <n> <ns>" before each command and its result after
# it, and stop at their first error.  Times are time.monotonic_ns(), which
# is gethrtime(), as DTrace's timestamp.
#
import hashlib
import os
import random
import re
import shutil
import subprocess
import sys
import time

MAXN = 5000		# commands per loop: bounds the key files
MAXNS = 120 * 10**9	# and a loop's running time
PROPS = "oxide:epoch,keylocation,keystatus,encryptionroot,mounted," \
    "canmount,mountpoint,zoned"


def now():
	return time.monotonic_ns()


def run(args):
	"""-> (rc, stdout, stderr on one line, start ns, end ns)"""
	t0 = now()
	p = subprocess.run(args, stdin=subprocess.DEVNULL,
	    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
	err = p.stderr.decode(errors="replace").strip().replace("\n", " | ")
	return (p.returncode, p.stdout.decode(errors="replace"), err, t0,
	    now())


def keyfile(d, e):
	"""Epoch e's key: epoch 0 is the key setup() created crypt with."""
	if e == 0:
		return d + "/key"
	return "%s/act_keyrotate.keys/k%d" % (d, e)


def rootkey(d, i):
	return "%s/act_keyrotate.keys/r%d" % (d, i)


def mountdir(d, i):
	return "%s/act_keyrotate.mnt/kr%d" % (d, i)


def newkey(path):
	fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
	try:
		if os.write(fd, os.urandom(32)) != 32:
			raise OSError("short write to %s" % path)
	finally:
		os.close(fd)


def pattern(i):
	h = hashlib.sha256(b"kr%d" % i).digest()
	return h * (8192 // len(h))


def on_mount(dfd, path):
	"""Is dfd (opened from path) the root of a file system mounted there?"""
	return os.fstat(dfd).st_dev != os.stat(os.path.dirname(path)).st_dev


def rotate(pool, d):
	out = open(d + "/act_keyrotate.rot", "w", buffering=1)
	out.write("pid %d\n" % os.getpid())
	end = now() + MAXNS
	e = 0
	while e < MAXN and now() < end:
		e += 1
		k = keyfile(d, e)
		newkey(k)
		out.write("A K %d %d\n" % (e, now()))
		rc, _, err, t0, t1 = run(["zfs", "change-key",
		    "-o", "keylocation=file://" + k,
		    "-o", "oxide:epoch=%d" % e, pool + "/crypt"])
		out.write("K %d %d %d %d\n" % (e, rc, t0, t1))
		if rc != 0:
			out.write("E K %d %s\n" % (e, err))
			break
	out.write("end %d\n" % now())


def write_file(mnt, i):
	"""Create <mnt>/f, write it and fsync it: 0, or an errno (< 0: ours)."""
	dfd = fd = -1
	try:
		dfd = os.open(mnt, os.O_RDONLY)
		# Write only through the mounted root: if the export unmounted
		# it first, the file would land in the directory under it.
		if not on_mount(dfd, mnt):
			return -1
		fd = os.open("f", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644,
		    dir_fd=dfd)
		b = pattern(i)
		if os.write(fd, b) != len(b):
			return -2
		os.fsync(fd)
		return 0
	except OSError as x:
		return x.errno if x.errno else -3
	finally:
		for f in (fd, dfd):
			if f >= 0:
				try:
					os.close(f)
				except OSError:
					pass


def churn(pool, d, seed):
	rnd = random.Random(seed)
	out = open(d + "/act_keyrotate.churn", "w", buffering=1)
	out.write("pid %d\n" % os.getpid())
	end = now() + MAXNS
	i = 0
	while i < MAXN and now() < end:
		i += 1
		ds = "%s/crypt/kr%d" % (pool, i)
		mount = rnd.random() < 0.5
		inherit = rnd.random() < 0.35
		k = rootkey(d, i)
		newkey(k)
		args = ["zfs", "create", "-o", "encryption=aes-256-gcm",
		    "-o", "keyformat=raw", "-o", "keylocation=file://" + k]
		if mount:
			args += ["-o", "mountpoint=" + mountdir(d, i)]
		else:
			args += ["-o", "canmount=off"]
		out.write("A C %d %d\n" % (i, now()))
		rc, _, err, t0, t1 = run(args + [ds])
		# zfs create prints this only after the create and its
		# properties returned 0 (synced), when just the mount failed.
		made = 1 if rc == 0 or "successfully created" in err else 0
		out.write("C %d %d %d %d %d %d\n" %
		    (i, rc, made, int(mount), t0, t1))
		if rc != 0:
			out.write("E C %d %s\n" % (i, err))
			break
		if mount:
			out.write("A W %d %d\n" % (i, now()))
			t0 = now()
			e = write_file(mountdir(d, i), i)
			out.write("W %d %d %d %d\n" % (i, e, t0, now()))
			if e != 0:
				out.write("E W %d %d\n" % (i, e))
				break
		if inherit:
			out.write("A I %d %d\n" % (i, now()))
			rc, _, err, t0, t1 = run(["zfs", "change-key", "-i", ds])
			out.write("I %d %d %d %d\n" % (i, rc, t0, t1))
			if rc != 0:
				out.write("E I %d %s\n" % (i, err))
				break
		out.write("A D %d %d\n" % (i, now()))
		rc, _, err, t0, t1 = run(["zfs", "destroy", ds])
		sure = 0
		if rc == 0:
			# zfs destroy also returns 0 when the destroy ioctl gets
			# ENOENT, as it does if the export removed the pool
			# after zfs_open().  The pool still being there after
			# the destroy rules that out.
			if run(["zpool", "list", "-H", "-o", "name", pool])[0] == 0:
				sure = 1
		out.write("D %d %d %d %d %d\n" % (i, rc, sure, t0, t1))
		if rc != 0 or not sure:
			out.write("E D %d %s\n" % (i, err if rc else "pool gone"))
			break
	out.write("end %d\n" % now())


# verify


def ints(fields):
	try:
		return [int(x) for x in fields]
	except ValueError:
		return None


def parse(path):
	try:
		with open(path) as f:
			return [l.split() for l in f]
	except OSError:
		return []


def spa_fail_ns(d):
	"""When the pool failed (chaos.d's spa_fail line), or None."""
	try:
		with open(d + "/d.out") as f:
			for l in f:
				w = l.split()
				if len(w) >= 2 and w[0] == "spa_fail" and \
				    w[1].isdigit():
					return int(w[1])
	except OSError:
		pass
	return None


def zget(top):
	rc, out, err, _, _ = run(["zfs", "get", "-H", "-p", "-d", "1",
	    "-t", "filesystem,volume", "-o", "name,property,value", PROPS, top])
	props = {}
	for l in out.splitlines():
		f = l.split("\t")
		if len(f) == 3:
			props.setdefault(f[0], {})[f[1]] = f[2]
	return rc, err, props


def dry(ds, key):
	"""Does key decrypt ds?  (zfs load-key -n checks it, loaded or not.)"""
	rc, _, err, _, _ = run(["zfs", "load-key", "-n", "-L", "file://" + key,
	    ds])
	return rc == 0, err


def which_key(ds, d, epoch, tried):
	cands = []
	for e in [epoch] + list(range(tried, max(-1, tried - 40), -1)) + [0]:
		if e is not None and e >= 0 and e not in cands and \
		    os.path.isfile(keyfile(d, e)):
			cands.append(e)
	for e in cands:
		if dry(ds, keyfile(d, e))[0]:
			return "the epoch-%d key decrypts it" % e
	return "none of the keys of epochs %s decrypts it" % \
	    ",".join(str(e) for e in cands)


def ensure_mounted(ds, p, problems, notes):
	"""Is ds mounted (mounting it if mount -a should have)?"""
	if p.get("mounted") == "yes":
		return True
	if p.get("keystatus") != "available" or p.get("canmount") != "on" or \
	    p.get("zoned") == "on" or \
	    p.get("mountpoint") in ("none", "legacy", "-", None):
		return False
	rc, _, err, _, _ = run(["zfs", "mount", ds])
	if rc != 0:
		problems.append("%s: its key is loaded, but it doesn't mount: %s" %
		    (ds, err))
		return False
	notes.append("%s: zfs mount -a left it unmounted; zfs mount worked" % ds)
	return True


def check_file(mnt, i):
	"""None if <mnt>/f holds what write_file() wrote, else what's wrong."""
	try:
		dfd = os.open(mnt, os.O_RDONLY)
	except OSError as x:
		return "cannot open %s: %s" % (mnt, x.strerror)
	try:
		if not on_mount(dfd, mnt):
			return "%s is not a mount point" % mnt
		fd = os.open("f", os.O_RDONLY, dir_fd=dfd)
		data = b""
		try:
			while len(data) <= 8192:
				b = os.read(fd, 16384)
				if not b:
					break
				data += b
		finally:
			os.close(fd)
	except OSError as x:
		return "%s/f: %s" % (mnt, x.strerror)
	finally:
		os.close(dfd)
	if data != pattern(i):
		return "%s/f has %d bytes that don't match what was written" % \
		    (mnt, len(data))
	return None


def verify(pool, d, it):
	crypt = pool + "/crypt"
	problems, notes, stops = [], [], []
	failns = spa_fail_ns(d)
	rc, err, props = zget(crypt)
	if rc != 0:
		notes.append("zfs get exited %d: %s" % (rc, err))

	# Key rotation on crypt.
	tried, done = 0, []
	for f in parse(d + "/act_keyrotate.rot"):
		if f and f[0] == "E":
			stops.append("rotation: " + " ".join(f[1:]))
		elif len(f) == 4 and f[0] == "A" and f[1] == "K":
			v = ints(f[2:3])
			if v:
				tried = max(tried, v[0])
		elif len(f) == 5 and f[0] == "K":
			v = ints(f[1:])
			if v:
				done.append(v)
	acked = max([e for (e, r, _, _) in done if r == 0] + [0])
	for (e, r, t0, t1) in done:
		if r == 0 and failns is not None and t0 > failns:
			# The ioctl came ms after t0, into a txg that can't
			# commit, so the sync task must have returned EIO.
			problems.append("change-key to epoch %d started %.3f s "
			    "after the pool failed, but returned 0" %
			    (e, (t0 - failns) / 1e9))
		if r != 0 and failns is not None and t1 < failns:
			# Not a failure (a suspended pool fails it with EAGAIN,
			# say), but the loop stopped early.
			notes.append("change-key to epoch %d failed %.3f s "
			    "before the pool did" % (e, (failns - t1) / 1e9))

	c = props.get(crypt)
	epoch = None
	if c is None:
		problems.append("%s is missing after the import (%s)" %
		    (crypt, err))
	else:
		es = c.get("oxide:epoch", "-")
		kl = c.get("keylocation", "?")
		ks = c.get("keystatus", "?")
		try:
			epoch = int(es)
		except ValueError:
			# setup's zfs set oxide:epoch=0 returned 0: it synced.
			problems.append("%s: oxide:epoch is %r" % (crypt, es))
		if epoch is not None:
			# A change-key that returned 0 synced, so the epoch
			# can't be older; only our change-keys set it.
			if epoch < acked:
				problems.append("%s: oxide:epoch is %d, but "
				    "zfs change-key to epoch %d returned 0" %
				    (crypt, epoch, acked))
			if epoch > tried:
				problems.append("%s: oxide:epoch is %d, but no "
				    "change-key past epoch %d was tried" %
				    (crypt, epoch, tried))
			# spa_keystore_change_key_sync() sets keylocation,
			# oxide:epoch and the new wrapping key in one sync task.
			want = "file://" + keyfile(d, epoch)
			if kl != want:
				problems.append("%s: oxide:epoch %d, but "
				    "keylocation %s (change-key sets both in one "
				    "sync task)" % (crypt, epoch, kl))
		if not kl.startswith("file://") or not os.path.isfile(kl[7:]):
			problems.append("%s: keylocation %s names no key file" %
			    (crypt, kl))
		if c.get("encryptionroot") != crypt:
			problems.append("%s: encryptionroot %s" %
			    (crypt, c.get("encryptionroot")))
		if ks != "available":
			problems.append("%s: keystatus %s after zfs load-key -r "
			    "(keylocation %s, oxide:epoch %s): %s" % (crypt, ks,
			    kl, es, which_key(crypt, d, epoch, tried)))
		elif epoch is not None and os.path.isfile(keyfile(d, epoch)):
			ok, e2 = dry(crypt, keyfile(d, epoch))
			if not ok:
				problems.append("%s: its key is loaded, but the "
				    "epoch-%d key doesn't decrypt it (%s): %s" %
				    (crypt, epoch, e2,
				    which_key(crypt, d, None, tried)))
		# Their DSL crypto keys must unwrap with the loaded key: a
		# child rewrapped in another txg than crypt wouldn't mount.
		for ds in (crypt, crypt + "/zone"):
			if ds in props:
				ensure_mounted(ds, props[ds], problems, notes)

	# Encryption-root churn under crypt.
	roots = {}
	for f in parse(d + "/act_keyrotate.churn"):
		if not f:
			continue
		if f[0] == "E":
			stops.append("churn: " + " ".join(f[1:]))
			continue
		if f[0] == "A" and len(f) == 4:
			v = ints(f[2:3])
			if v:
				roots.setdefault(v[0], {})["try" + f[1]] = 1
			continue
		if f[0] not in ("C", "W", "I", "D"):
			continue
		v = ints(f[1:])
		if not v:
			continue
		r = roots.setdefault(v[0], {})
		if f[0] == "C" and len(v) == 6:
			r.update(C=v[1], made=v[2], mount=v[3], tC=v[4])
			bad, end = v[1] != 0, v[5]
		elif f[0] == "W" and len(v) == 4:
			r.update(W=v[1], tW=v[2])
			bad, end = v[1] != 0, v[3]
		elif f[0] == "I" and len(v) == 4:
			r.update(I=v[1], tI=v[2])
			bad, end = v[1] != 0, v[3]
		elif f[0] == "D" and len(v) == 5:
			r.update(D=v[1], Dsure=v[2], tD=v[3])
			bad, end = v[1] != 0, v[4]
		else:
			continue
		if bad and failns is not None and end < failns:
			notes.append("kr%d: %s failed %.3f s before the pool did" %
			    (v[0], f[0], (failns - end) / 1e9))
	if failns is not None:
		for i in sorted(roots):
			r = roots[i]
			for what, ok, t in (
			    ("zfs create", r.get("made") == 1, r.get("tC")),
			    ("fsync", r.get("W") == 0, r.get("tW")),
			    ("zfs change-key -i", r.get("I") == 0, r.get("tI")),
			    ("zfs destroy", r.get("D") == 0 and
			    r.get("Dsure") == 1, r.get("tD"))):
				if ok and t is not None and t > failns:
					problems.append("kr%d: %s started %.3f s "
					    "after the pool failed, but returned 0"
					    % (i, what, (t - failns) / 1e9))

	pat = re.compile("^" + re.escape(crypt) + r"/kr(\d+)$")
	exist = set()
	for name in props:
		m = pat.match(name)
		if m:
			exist.add(int(m.group(1)))
	made = sum(1 for r in roots.values() if r.get("made") == 1)
	left, nokl = [], 0
	for i in sorted(set(roots) | exist):
		r = roots.get(i, {})
		ds = "%s/kr%d" % (crypt, i)
		p = props.get(ds)
		if p is None:
			# Created in a synced txg; only our destroy removes it.
			if r.get("made") == 1 and not r.get("tryD"):
				problems.append("%s: zfs create returned 0 and it "
				    "was never destroyed, but it is gone" % ds)
			continue
		if not r.get("tryC"):
			problems.append("%s: there after the import, but the "
			    "log has no create for it" % ds)
			continue
		if r.get("D") == 0 and r.get("Dsure") == 1:
			problems.append("%s: zfs destroy returned 0 with the "
			    "pool still imported, but it is back" % ds)
			continue
		root = p.get("encryptionroot", "?")
		how = []
		if r.get("I") == 0 and root != crypt:
			problems.append("%s: zfs change-key -i returned 0, but "
			    "its encryptionroot is %s" % (ds, root))
		elif not r.get("tryI") and root != ds:
			problems.append("%s: never inherited a key, but its "
			    "encryptionroot is %s" % (ds, root))
		if root == ds:
			how.append("own key")
			kl = p.get("keylocation", "?")
			want = "file://" + rootkey(d, i)
			if kl == want:
				if p.get("keystatus") != "available":
					ok, e2 = dry(ds, rootkey(d, i))
					problems.append("%s: keylocation %s, but zfs "
					    "load-key -r left it %s (that key %s)" %
					    (ds, kl, p.get("keystatus"),
					    "decrypts it" if ok else
					    "doesn't decrypt it: " + e2))
			elif kl == "none" and r.get("made") != 1:
				# zfs_ioc_create() sets keylocation in a sync
				# task after the one that creates the dataset
				# and its key; the create didn't return 0, so
				# only the first one may have landed.
				nokl += 1
				how.append("no keylocation")
				ok, e2 = dry(ds, rootkey(d, i))
				if not ok:
					problems.append("%s: created without its "
					    "keylocation, and its own key doesn't "
					    "decrypt it: %s" % (ds, e2))
			else:
				problems.append("%s: keylocation %s, expected "
				    "%s%s" % (ds, kl, want,
				    " (zfs create returned 0)" if
				    r.get("made") == 1 else ""))
		elif root == crypt:
			how.append("inherited")
		else:
			problems.append("%s: encryptionroot %s" % (ds, root))
		mounted = ensure_mounted(ds, p, problems, notes)
		if mounted:
			how.append("mounted")
		if r.get("W") == 0 and mounted:
			bad = check_file(p.get("mountpoint", "?"), i)
			if bad:
				problems.append("%s: fsync of f returned 0, but "
				    "after the import: %s" % (ds, bad))
			else:
				how.append("f ok")
		left.append("kr%d(%s)" % (i, ",".join(how)))

	summary = "oxide:epoch %s (acked %d, tried %d); roots %d made, " \
	    "%d left%s" % ("?" if epoch is None else epoch, acked, tried,
	    made, len(left), (" " + " ".join(left)) if left else "")
	if nokl:
		summary += ", %d without keylocation" % nokl
	if failns is None:
		summary += ", no spa_fail time"
	if notes:
		summary += "; %d notes" % len(notes)
	with open(d + "/act_keyrotate.verify", "w") as f:
		f.write(summary + "\n")
		for x in problems:
			f.write("PROBLEM " + x + "\n")
		for x in notes:
			f.write("note " + x + "\n")
		for x in stops:
			f.write("stopped " + x + "\n")
	if not problems:
		print("keyrotate ok: " + summary)
		return 0
	keep = "%s/act_keyrotate.fail.%s" % (d, it)
	try:
		os.makedirs(keep, exist_ok=True)
		for n in ("rot", "churn", "verify", "out"):
			if os.path.exists(d + "/act_keyrotate." + n):
				shutil.copy(d + "/act_keyrotate." + n, keep)
	except OSError:
		pass
	print("keyrotate FAIL: %s%s; %s (details in %s)" % (problems[0],
	    " (+%d more)" % (len(problems) - 1) if len(problems) > 1 else "",
	    summary, keep))
	return 1


def main():
	mode = sys.argv[1]
	if mode in ("rotate", "churn"):
		# Our own output (a traceback, say) goes to act_keyrotate.out.
		fd = os.open(sys.argv[3] + "/act_keyrotate.out",
		    os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
		os.dup2(fd, 1)
		os.dup2(fd, 2)
		os.close(fd)
	if mode == "rotate":
		rotate(sys.argv[2], sys.argv[3])
	elif mode == "churn":
		churn(sys.argv[2], sys.argv[3], int(sys.argv[4]))
	elif mode == "verify":
		try:
			rc = verify(sys.argv[2], sys.argv[3], sys.argv[4])
		except Exception as x:
			# A bug here, not in ZFS: stop so that it gets fixed.
			print("keyrotate: VERIFY BUG (not a ZFS failure): %s: %s" %
			    (type(x).__name__, x))
			rc = 2
		sys.exit(rc)
	else:
		sys.exit(2)


main()
EOF
}
