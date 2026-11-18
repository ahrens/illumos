#
# mmap_hold.py <file> <bytes>: map the file MAP_SHARED, dirty every page
# once (no msync), then hold the mapping until killed.  When the pool fails
# the dirty pages can't be written: unmapping them before the export takes
# zfs_inactive()'s drop path, after it the detached file system's.
#
import mmap
import os
import signal
import sys

path, size = sys.argv[1], int(sys.argv[2])
fd = os.open(path, os.O_RDWR)
m = mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
for off in range(0, size, 4096):
	m[off] = (m[off] + 1) % 256
print("dirty", flush=True)
while True:
	signal.pause()
