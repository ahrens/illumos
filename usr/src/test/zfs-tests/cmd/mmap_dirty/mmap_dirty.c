/*
 * This file and its contents are supplied under the terms of the
 * Common Development and Distribution License ("CDDL"), version 1.0.
 * You may only use this file in accordance with the terms of version
 * 1.0 of the CDDL.
 *
 * A full copy of the text of the CDDL should have accompanied this
 * source.  A copy of the CDDL is also available via the Internet at
 * http://www.illumos.org/license/CDDL.
 */

/*
 * Copyright 2026 Oxide Computer Company
 */

/*
 * mmap_dirty <file>: map the whole file shared, change a byte in each page,
 * and unmap and close it without msync(), leaving its dirty pages for the
 * file system to write once the file is no longer in use.
 */

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

int
main(int argc, char **argv)
{
	struct stat st;
	long pagesize = sysconf(_SC_PAGESIZE);
	unsigned char *p;
	int fd;

	if (argc != 2) {
		(void) fprintf(stderr, "usage: %s <file>\n", argv[0]);
		return (1);
	}
	if ((fd = open(argv[1], O_RDWR)) < 0 || fstat(fd, &st) != 0) {
		perror(argv[1]);
		return (2);
	}
	if (st.st_size == 0) {
		(void) fprintf(stderr, "%s: empty file\n", argv[1]);
		return (2);
	}
	p = mmap(NULL, st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) {
		perror("mmap");
		return (2);
	}
	for (off_t off = 0; off < st.st_size; off += pagesize)
		p[off] ^= 0xff;
	if (munmap(p, st.st_size) != 0 || close(fd) != 0) {
		perror("munmap/close");
		return (2);
	}
	return (0);
}
