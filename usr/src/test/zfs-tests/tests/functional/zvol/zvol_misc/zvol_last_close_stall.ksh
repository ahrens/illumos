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
# The last close of a zvol, which waits for a txg to sync, must not stall
# opens of other zvols.
#
# STRATEGY:
# 1. Create a zvol (othervol) and hold it open
# 2. Delay the I/O of $TESTPOOL so its txgs take a long time to sync, and
#    keep writing to a file system in it so the txgs aren't empty
# 3. Create another zvol (busyvol), and repeatedly write to it and close it
# 4. Meanwhile, repeatedly open and read othervol, timing each attempt
# 5. Verify that busyvol was closed at least once, and that no attempt took
#    more than MAX_OPEN_SECS
#
# Holding othervol open keeps the timed opens and closes from being first
# opens or last closes themselves.
#

verify_runnable "global"

typeset OTHER=/dev/zvol/rdsk/$TESTPOOL/othervol
typeset BUSY=/dev/zvol/rdsk/$TESTPOOL/busyvol
typeset FS=$TESTPOOL/lcsfs
typeset DONE=$TEST_BASE_DIR/zvol_last_close_stall.done
typeset CLOSES=$TEST_BASE_DIR/zvol_last_close_stall.closes
typeset -i MAX_OPEN_SECS=2
typeset -i MEASURE_SECS=60

function cleanup
{
	touch $DONE
	zinject -c all >/dev/null
	wait	# for the background jobs to finish their I/O
	exec 4<&-
	for ds in $TESTPOOL/busyvol $TESTPOOL/othervol $FS; do
		if datasetexists $ds; then
			log_must zfs destroy $ds
		fi
	done
	rm -f $DONE $CLOSES
}

log_assert "The last close of a zvol does not stall other zvols"
log_onexit cleanup

rm -f $DONE $CLOSES
log_must zfs create -V 100m $TESTPOOL/othervol
log_must zfs create -V 100m $TESTPOOL/busyvol
log_must zfs create $FS
typeset file=$(get_prop mountpoint $FS)/file

# Hold othervol open until we are done.
[[ -c $OTHER ]] || log_fail "$OTHER does not exist"
exec 4<$OTHER

log_must zinject -d $DISK -D 200:1 $TESTPOOL

# Keep the txgs from being empty.
(
	while [[ ! -f $DONE ]]; do
		dd if=/dev/zero of=$file bs=128k count=1 >/dev/null 2>&1
		sleep 0.2
	done
) &

# Dirty busyvol and close it, which is its last close, over and over.
(
	while [[ ! -f $DONE ]]; do
		dd if=/dev/zero of=$BUSY bs=128k count=8 >/dev/null 2>&1 &&
		    echo >>$CLOSES
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

typeset -i closes=$(wc -l <$CLOSES 2>/dev/null)
log_note "busyvol closed $closes times;" \
    "longest of $tries opens of othervol: ${longest}s"
(( closes > 0 )) || log_fail "busyvol was never written and closed"
(( longest <= MAX_OPEN_SECS )) || \
    log_fail "opening othervol took ${longest}s (max ${MAX_OPEN_SECS}s)"

log_pass "The last close of a zvol does not stall other zvols"
