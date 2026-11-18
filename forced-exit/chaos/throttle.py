import sys, time
rate = float(sys.argv[1]) * 1048576
i, o = sys.stdin.buffer, sys.stdout.buffer
start = time.time(); n = 0
while True:
	b = i.read(65536)
	if not b:
		break
	o.write(b); n += len(b)
	ahead = n / rate - (time.time() - start)
	if ahead > 0:
		time.sleep(ahead)
