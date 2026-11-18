# reuse.py <d.out>...: count allocations that overlap space unallocated
# (metaslab_unalloc_dva) earlier in the same txg; "open" ones are of space
# unallocated in open context (txg > the syncing txg, e.g. a failed
# dmu_sync() write, which the log may point to).  Exits 1 if any are open.
import sys
bad = 0
for path in sys.argv[1:]:
	un = {}		# (vdev, txg) -> list of (off, end, open)
	n = op = zil = 0
	for line in open(path):
		f = line.split()
		if not f or f[0] not in ("A", "U"):
			continue
		if f[0] == "A":
			kind, txg, dva = f[2], int(f[4]), f[5]
		else:
			kind, txg, dva = "U", int(f[3]), f[4]
		v, off, size = dva.split(":")
		v, off, size = int(v), int(off, 16), int(size, 16)
		l = un.setdefault((v, txg), [])
		if kind == "U":
			sync = int(f[6]) if len(f) > 6 and f[5] == "sync" else -1
			l.append((off, off + size, sync >= 0 and txg > sync))
			continue
		m = [o for o in l if o[0] < off + size and off < o[1]]
		if m:
			n += 1
			zil += kind == "zil"
			if any(o[2] for o in m):
				op += 1
				print("OPEN REUSE %s txg %d %d:%x:%x" % (kind, txg, v, off, size))
	print("%s: %d same-txg reuses (%d by zil), %d of open-context unallocations" % (path, n, zil, op))
	bad += op
sys.exit(1 if bad else 0)
