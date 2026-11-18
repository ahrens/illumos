#
# verify.py durable <path> <log>: every acknowledged record of a writer.py
# log must be on disk.  A create is durable only with the first write
# acknowledged after it, so a log with no acknowledged record checks nothing.
#
# verify.py afterfail <fail ns> <log>...: no write that started after the
# pool failed may have been acknowledged.
#
import hashlib
import os
import sys

BS = 131072


def records(log):
	acked = []
	try:
		for line in open(log):
			f = line.split()
			if len(f) == 3 and f[0].isdigit():
				acked.append((int(f[0]), int(f[1]), int(f[2])))
	except FileNotFoundError:
		pass
	return acked


def rec(i):
	h = hashlib.sha256(b"%d" % i).digest()
	return h * (BS // len(h))


def durable(path, log):
	acked = records(log)
	if not acked:
		print("%s: 0 acked" % path)
		return 0
	fd = os.open(path, os.O_RDONLY)
	bad = [i for (i, _, _) in acked if os.pread(fd, BS, i * BS) != rec(i)]
	os.close(fd)
	print("%s: %d acked, %d bad%s" % (path, len(acked), len(bad),
	    (" (first %s)" % bad[:5]) if bad else ""))
	return 1 if bad else 0


def afterfail(fail, logs):
	bad = 0
	for log in logs:
		late = [i for (i, t0, _) in records(log) if t0 > fail]
		if late:
			print("%s: %d writes started after the failure were "
			    "acknowledged (first %s)" % (log, len(late), late[:5]))
			bad = 1
	return bad


if sys.argv[1] == "durable":
	sys.exit(durable(sys.argv[2], sys.argv[3]))
elif sys.argv[1] == "afterfail":
	sys.exit(afterfail(int(sys.argv[2]), sys.argv[3:]))
sys.exit(2)
