#!/usr/bin/ksh

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
# Copyright (c) 2015, 2016 by Delphix. All rights reserved.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/perf/perf.shlib

function cleanup
{
	#
	# We're using many filesystems depending on the number of
	# threads for each test, and there's no good way to get a list
	# of all the filesystems that should be destroyed on cleanup
	# (i.e. the list of filesystems used for the last test ran).
	# Thus, we simply recreate the pool as a way to destroy all
	# filesystems and leave a fresh pool behind.
	#
	recreate_perf_pool

	#
	# Since we set this value to "1", we have to reset it back to
	# "0" here. Ideally we'd get the value contained before we
	# modified it, and then set it to that same value, but the
	# chance that it was not "0" to begin with are low, so we don't
	# bother adding that unnecessary complexity.
	#
	mdb_set_uint32 "zfs_nocacheflush" "0"
}

log_onexit cleanup

recreate_perf_pool

# Aim to fill the pool to 50% capacity while accounting for a 3x compressratio.
export TOTAL_SIZE=$(($(get_prop avail $PERFPOOL) * 3 / 2))

if [[ -n $PERF_REGRESSION_WEEKLY ]]; then
	export PERF_RUNTIME=${PERF_RUNTIME:-$PERF_RUNTIME_WEEKLY}
	export PERF_RUNTYPE=${PERF_RUNTYPE:-'weekly'}
	export PERF_NTHREADS=${PERF_NTHREADS:-'1 2 4 8 16 32 64 128'}
	export PERF_NTHREADS_PER_FS=${PERF_NTHREADS_PER_FS:-'0 1'}
	export PERF_SYNC_TYPES=${PERF_SYNC_TYPES:-'1'}
	export PERF_IOSIZES=${PERF_IOSIZES:-'8k'}

elif [[ -n $PERF_REGRESSION_NIGHTLY ]]; then
	export PERF_RUNTIME=${PERF_RUNTIME:-$PERF_RUNTIME_NIGHTLY}
	export PERF_RUNTYPE=${PERF_RUNTYPE:-'nightly'}
	export PERF_NTHREADS=${PERF_NTHREADS:-'1 4 16 64'}
	export PERF_NTHREADS_PER_FS=${PERF_NTHREADS_PER_FS:-'0 1'}
	export PERF_SYNC_TYPES=${PERF_SYNC_TYPES:-'1'}
	export PERF_IOSIZES=${PERF_IOSIZES:-'8k'}
fi

lun_list=$(pool_to_lun_list $PERFPOOL)
log_note "Collecting backend IO stats with lun list $lun_list"
export collect_scripts=(
    "kstat zfs:0 1"   "kstat"
    "vmstat -T d 1"        "vmstat"
    "mpstat -T d 1"        "mpstat"
    "iostat -T d -xcnz 1"  "iostat"
    "dtrace -Cs $PERF_SCRIPTS/io.d $PERFPOOL $lun_list 1" "io"
    "dtrace  -s $PERF_SCRIPTS/zil.d $PERFPOOL 1"          "zil"
    "dtrace  -s $PERF_SCRIPTS/profile.d"                  "profile"
    "dtrace  -s $PERF_SCRIPTS/offcpu-profile.d"           "offcpu-profile"
)

log_note "ZIL specific random write workload with $PERF_RUNTYPE settings"
do_fio_run random_writes.fio $TRUE $FALSE
log_pass "Measure IO stats during ZIL specific random write workload"
