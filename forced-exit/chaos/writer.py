#
# writer.py <path> <log> <mode> [nslots]: write 128K records, logging each
# acknowledged one as "<i> <start ns> <end ns>" (gethrtime, as DTrace's
# timestamp).  Modes: "fsync" (pwrite + fsync), "dsync" (O_DSYNC file),
# "zvol" (raw zvol, every write synchronous, at most nslots records).
#
# On the first error it logs "err <errno> <ns>" and keeps its descriptor open
# until killed, as a hung application would, so that the export runs with
# the file or volume still open.  A zvol writer that runs out of slots logs
# "full <ns>" and holds the same way.
#
import hashlib
import os
import signal
import sys
import time

path, log, mode = sys.argv[1], sys.argv[2], sys.argv[3]
nslots = int(sys.argv[4]) if len(sys.argv) > 4 else 0
BS = 131072
out = open(log, "w", buffering=1)
out.write("pid %d\n" % os.getpid())


def rec(i):
	h = hashlib.sha256(b"%d" % i).digest()
	return h * (BS // len(h))


def hold(what):
	out.write("%s %d\n" % (what, time.monotonic_ns()))
	while True:
		signal.pause()


flags = os.O_RDWR
if mode != "zvol":
	flags |= os.O_CREAT
if mode in ("dsync", "zvol"):
	flags |= os.O_DSYNC
try:
	fd = os.open(path, flags, 0o644)
	if mode == "fsync":
		os.fsync(fd)
except OSError as e:
	hold("err %d" % e.errno)
out.write("created %d\n" % time.monotonic_ns())

i = 0
while nslots == 0 or i < nslots:
	t0 = time.monotonic_ns()
	try:
		os.pwrite(fd, rec(i), i * BS)
		if mode == "fsync":
			os.fsync(fd)
	except OSError as e:
		hold("err %d" % e.errno)
	out.write("%d %d %d\n" % (i, t0, time.monotonic_ns()))
	i += 1
hold("full")
