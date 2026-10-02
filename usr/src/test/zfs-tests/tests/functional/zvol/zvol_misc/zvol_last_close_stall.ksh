#!/usr/bin/ksh -p
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
. $STF_SUITE/tests/functional/zvol/zvol_common.shlib

#
# DESCRIPTION:
# The last close of a zvol with dirty data must not stall opens of other
# zvols.
#
# The last close waits for the zvol's dirty data to be synced, and used to
# do so while holding zfsdev_state_lock, which every zvol open, close and
# ioctl needs.
#
# STRATEGY:
# 1. Create a zvol (othervol) and hold it open
# 2. Delay the I/O of $TESTPOOL so its txgs take a long time to sync
# 3. Create another zvol (busyvol), and repeatedly write to it and close it
# 4. Meanwhile, repeatedly open and read othervol, timing each attempt
# 5. Verify that no attempt took more than MAX_OPEN_SECS
#
# Holding othervol open keeps the timed opens and closes from being first
# opens or last closes themselves.
#

verify_runnable "global"

typeset OTHER=/dev/zvol/rdsk/$TESTPOOL/othervol
typeset BUSY=/dev/zvol/rdsk/$TESTPOOL/busyvol
typeset HELD=$TEST_BASE_DIR/zvol_last_close_stall.held
typeset MEASURED=$TEST_BASE_DIR/zvol_last_close_stall.measured
typeset -i MAX_OPEN_SECS=2
typeset -i MEASURE_SECS=60

function cleanup
{
	touch $MEASURED
	zinject -c all >/dev/null
	wait	# for the background jobs to close the zvols
	for vol in busyvol othervol; do
		if datasetexists $TESTPOOL/$vol; then
			log_must zfs destroy $TESTPOOL/$vol
		fi
	done
	rm -f $HELD $MEASURED
}

log_assert "The last close of a zvol does not stall other zvols"
log_onexit cleanup

rm -f $HELD $MEASURED
log_must zfs create -V 100m $TESTPOOL/othervol
log_must zfs create -V 100m $TESTPOOL/busyvol

# Hold othervol open until we are done measuring.
(
	exec 4<$OTHER
	touch $HELD
	while [[ ! -f $MEASURED ]]; do
		sleep 0.5
	done
) &
for (( i = 0; i < 30; i++ )); do
	[[ -f $HELD ]] && break
	sleep 1
done
[[ -f $HELD ]] || log_fail "could not open $OTHER"

log_must zinject -d $DISK -D 200:1 $TESTPOOL

# Dirty busyvol and close it, which is its last close, over and over.
(
	while [[ ! -f $MEASURED ]]; do
		dd if=/dev/urandom of=$BUSY bs=128k count=8 >/dev/null 2>&1
	done
) &

typeset -F3 start elapsed longest=0
typeset -i tries=0
typeset -i end=$((SECONDS + MEASURE_SECS))
while (( SECONDS < end )); do
	start=$SECONDS
	dd if=$OTHER of=/dev/null bs=512 count=1 >/dev/null 2>&1 ||
	    log_fail "read from $OTHER failed"
	elapsed=$((SECONDS - start))
	(( elapsed > longest )) && longest=$elapsed
	(( tries++ ))
	sleep 0.1
done
touch $MEASURED

log_note "longest of $tries opens of othervol: ${longest}s"
(( longest <= MAX_OPEN_SECS )) || \
    log_fail "opening othervol took ${longest}s (max ${MAX_OPEN_SECS}s)"

log_pass "The last close of a zvol does not stall other zvols"
