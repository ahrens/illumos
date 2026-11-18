#
# poller.py <log> <interval s> <pool>...: run the commands sled-agent's
# inventory and reconcilers run (zpool list/status/get, zfs list/get), over
# and over, logging "<start ns> <ms> <rc> <command>" for each.  A command
# that takes too long is what a sled would see as a hang.
#
import subprocess
import sys
import time

log, interval, pools = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
out = open(log, "w", buffering=1)
cmds = []
for p in pools:
	cmds += [
	    ["zpool", "list", "-Hpo", "name,size,allocated,free,health", p],
	    ["zpool", "get", "-Hp", "health,failmode", p],
	    ["zpool", "status", "-x", p],
	    ["zfs", "list", "-Hpr", "-o", "name,used,avail,mountpoint", p],
	    ["zfs", "get", "-Hpr", "-t", "filesystem,volume", "encryption,keystatus,quota,reservation", p],
	]
while True:
	for c in cmds:
		t0 = time.monotonic_ns()
		try:
			rc = subprocess.run(c, stdout=subprocess.DEVNULL,
			    stderr=subprocess.DEVNULL).returncode
		except Exception:
			rc = -1
		ms = (time.monotonic_ns() - t0) // 1000000
		out.write("%d %d %d %s\n" % (t0, ms, rc, " ".join(c[:2])))
	time.sleep(interval)
