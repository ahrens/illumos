#!/bin/ksh -p
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# http://www.illumos.org/license/CDDL.
#

#
# Copyright 2026 Oxide Computer Company
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/failmode/failmode.kshlib

#
# DESCRIPTION:
#	A pool whose only disk fails every write but still answers probes
#	stops: it suspends (failmode=wait or continue) or fails
#	(failmode=death).  Nothing faults the disk, so a failed write would
#	otherwise be reexecuted forever (see zio_reexecute_max).  Once the
#	disk works again, a suspended pool resumes and a failed one can be
#	exported and imported, with the data synced before intact.
#
# STRATEGY:
#	For each failmode:
#	1. Create a pool on a file vdev, write data and sync it
#	2. Make every write to the vdev fail, leaving the probes alone
#	3. Dirty the pool; it must suspend or fail within 30 seconds
#	4. Clear the injection.  wait, continue: zpool clear resumes the
#	   pool.  death: zpool export -f removes it, and it imports again.
#	5. The data synced before is intact, and a scrub finds no errors
#

verify_runnable "global"

log_assert "A pool whose disk fails writes but answers probes stops"
log_onexit failmode_cleanup

for mode in wait continue death; do
	log_note "failmode=$mode"
	failmode_create_pool $mode
	typeset fs=$(get_prop mountpoint $TESTPOOL/$TESTFS)
	log_must dd if=/dev/urandom of=$fs/data bs=128k count=16
	sync_pool $TESTPOOL
	typeset cksum=$(sha256digest $fs/data)

	log_must zinject -d $FAILMODE_VDEV -e io -T write $TESTPOOL
	log_must dd if=/dev/urandom of=$fs/dirty bs=128k count=8
	failmode_wait_stopped $TESTPOOL $mode

	if [[ $mode == death ]]; then
		log_mustnot pool_is_suspended $TESTPOOL
		# zinject handlers hold the pool.
		log_must zinject -c all
		run_within 60 "zpool export -f of the failed pool" \
		    zpool export -f $TESTPOOL
		log_must test $within_rc -eq 0
		log_mustnot poolexists $TESTPOOL
		log_must zpool import -d $TEST_BASE_DIR $TESTPOOL
	else
		log_mustnot pool_has_failed $TESTPOOL
		failmode_resume_pool
		sync_pool $TESTPOOL
	fi

	log_must test "$cksum" = "$(sha256digest $fs/data)"
	log_must zpool scrub -w $TESTPOOL
	log_must check_pool_status $TESTPOOL "errors" "No known data errors"
	failmode_cleanup
done

log_pass "A pool whose disk fails writes but answers probes stops"
