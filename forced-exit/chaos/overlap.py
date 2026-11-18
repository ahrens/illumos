# overlap.py <d.out>: report allocations that overlap a live allocation made
# less than 3 txgs earlier with no metaslab_unalloc_dva() of it in between.
# (Deferred frees aren't traced, but their space can't be reused that soon.)
import sys, bisect
live = {}	# vdev -> sorted list of (off, end, txg, kind, ts)
bad = 0
for line in open(sys.argv[1]):
	f = line.split()
	if not f or f[0] not in ("A", "U"):
		continue
	if f[0] == "A":
		ts, kind, txg, dva = int(f[1]), f[2], int(f[4]), f[5]
	else:
		ts, kind, txg, dva = int(f[1]), "U", int(f[3]), f[4]
	v, off, size = dva.split(":")
	v, off, size = int(v), int(off, 16), int(size, 16)
	end = off + size
	l = live.setdefault(v, [])
	i = bisect.bisect_left(l, (off,))
	if kind == "U":
		for j in (i - 1, i):
			if 0 <= j < len(l) and l[j][0] == off and l[j][1] == end:
				del l[j]
				break
		continue
	for j in (i - 1, i, i + 1):
		if 0 <= j < len(l) and l[j][0] < end and off < l[j][1]:
			o = l[j]
			if txg - o[2] < 3:
				bad += 1
				print("OVERLAP %d:%x:%x %s txg %d ts %d, live %d:%x:%x %s txg %d ts %d" %
				    (v, off, size, kind, txg, ts, v, o[0], o[1] - o[0], o[3], o[2], o[4]))
			del l[j]
			break
	bisect.insort(l, (off, end, txg, kind, ts))
sys.exit(1 if bad else 0)
