#!/bin/bash
# zlr.sh <pool> [extra ztest args]: zloop in /<pool> for ZLT seconds in total
# (default 12 h), restarting it if it exits early (it does when ztest crashes
# while the pool is exported).  Cores are named core.<prog>.<pid>.
P=$1; shift
cd /$P || exit 1
coreadm -p core.%f.%p $$
end=$(( $(date +%s) + ${ZLT:-43200} ))
n=0
while :; do
	left=$(( end - $(date +%s) ))
	[ $left -le 60 ] && break
	n=$((n + 1))
	mkdir -p /$P/work
	echo "$(date -u) zloop start $n, ${left}s left" >> /$P/zlr.log
	start=$(date +%s)
	/usr/bin/zloop -t $left -f /$P/work -c /$P/cores ${1:+-- "$@"} > /$P/zloop.out.$n 2>&1
	rc=$?
	echo "$(date -u) zloop $n exited $rc" >> /$P/zlr.log
	if [ $(( $(date +%s) - start )) -lt 120 ]; then
		echo "$(date -u) zloop $n ran under 2 min; stopping" >> /$P/zlr.log
		break
	fi
	# Keep whatever the early exit left behind.
	mkdir -p /$P/cores && mv /$P/work /$P/cores/zlr-leftover-$n 2>/dev/null
done
