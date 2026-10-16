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
. $STF_SUITE/tests/functional/failmode/forced_export_pinned.kshlib

#
# DESCRIPTION:
#	"zpool export -F" frees a send, a receive and a diff that are blocked
#	on their pipes, without signalling them: each one's ioctl fails, the
#	commands exit with an error rather than being killed, and the pool
#	exports.  A send whose process is stopped can't be freed: the export
#	returns EBUSY, and succeeds once the process is continued.
#
# STRATEGY:
#	1. Start a send to a fifo that is never read, a receive (-s) from a
#	   fifo whose writer has stopped writing, and a diff whose output is
#	   never read.  Each one blocks.
#	2. zpool export -F succeeds within 60 seconds, and the three commands
#	   exit 1.  Import, scrub, and finish the receive.
#	3. Start a send to a fifo that is never read, and stop it.  zpool
#	   export -F returns EBUSY.  Continue the send: zpool export -f
#	   succeeds, and the send exits 1.
#

typeset SRC=$PIN_POOL2/src
typeset FS=$TESTPOOL/$TESTFS
typeset -a cmdpids

function cleanup
{
	pkill -CONT -f "[z]fs send $FS" >/dev/null 2>&1
	pkill -9 -f "[z]fs (send|recv|diff) " >/dev/null 2>&1
	pin_cleanup
}

#
# Run "zfs <args>" in the background, with its stdin and stdout redirected
# by <redirs>, saving its stderr in $PIN_DIR/<name>.err and its exit status
# in $PIN_DIR/<name>.rc.
#
function start_zfs # name redirs args...
{
	typeset name=$1 redirs=$2
	shift 2
	rm -f $PIN_DIR/$name.rc
	eval "(zfs $* $redirs 2>$PIN_DIR/$name.err;" \
	    "echo \$? > $PIN_DIR/$name.rc) &"
	cmdpids[${#cmdpids[@]}]=$!
}

# The command must have exited 1: failed, not killed.
function check_exit # name
{
	typeset -i t=30
	while [[ ! -s $PIN_DIR/$1.rc ]]; do
		((t-- == 0)) && log_fail "zfs $1 is still running"
		sleep 1
	done
	typeset rc=$(cat $PIN_DIR/$1.rc)
	log_note "zfs $1 exited $rc: $(cat $PIN_DIR/$1.err)"
	[[ $rc == 1 ]] || log_fail "zfs $1 exited $rc, not 1"
}

function check_running # name...
{
	typeset n
	for n in "$@"; do
		[[ -e $PIN_DIR/$n.rc ]] && log_fail "zfs $n ended too soon:" \
		    "$(cat $PIN_DIR/$n.err)"
	done
	echo "::pgrep zfs | ::walk thread | ::findstack" | mdb -k
}

log_assert "zpool export -F frees a send, a receive and a diff blocked on" \
    "their pipes"
log_onexit cleanup

pin_mkpools
log_must zfs create -o compression=off $FS
log_must dd if=/dev/urandom of=/$FS/f bs=1024k count=64
log_must zfs snapshot $FS@s
#
# The kernel's diff coalesces runs of objects that are in use, or free, into
# one record.  Free every other object, so that it writes about 40000
# records, more than its pipe holds.
#
log_must mkdir /$FS/d
typeset -i i
for ((i = 0; i < 40000; i += 2)); do
	: > /$FS/d/a$i
	: > /$FS/d/b$i
done
log_must eval "find /$FS/d -name 'b*' -exec rm {} +"
log_must zfs snapshot $FS@d
log_must zfs create -o compression=off $SRC
log_must dd if=/dev/urandom of=/$SRC/f bs=1024k count=64
log_must zfs snapshot $SRC@s
log_must eval "zfs send $SRC@s > $PIN_DIR/stream"

typeset n
for n in send recv diff; do
	log_must mkfifo $PIN_DIR/$n.fifo
done
# Readers that never read, and a writer that stops writing after 8MB.
pin_bg eval "sleep 3600 < $PIN_DIR/send.fifo"
pin_bg eval "sleep 3600 < $PIN_DIR/diff.fifo"
pin_bg eval "{ dd if=$PIN_DIR/stream bs=1024k count=8 2>/dev/null;" \
    "sleep 3600; } > $PIN_DIR/recv.fifo"

start_zfs send "> $PIN_DIR/send.fifo" send $FS@s
start_zfs recv "< $PIN_DIR/recv.fifo" recv -s $TESTPOOL/dst
start_zfs diff "> $PIN_DIR/diff.fifo" diff $FS@s $FS@d
sleep 10
check_running send recv diff

run_within 60 "zpool export -F with the streams blocked" \
    zpool export -F $TESTPOOL
log_must test $within_rc -eq 0
log_mustnot poolexists $TESTPOOL
check_exit send
check_exit recv
check_exit diff
pin_kill_bg

pin_reimport
pin_finish_recv $SRC $SRC@s $TESTPOOL/dst

# A stopped send isn't asleep, and so can't be woken.
rm -f $PIN_DIR/send.fifo
log_must mkfifo $PIN_DIR/send.fifo
pin_bg eval "sleep 3600 < $PIN_DIR/send.fifo"
start_zfs send "> $PIN_DIR/send.fifo" send $FS@s
sleep 5
check_running send
log_must pkill -STOP -f "[z]fs send $FS"
sleep 1
run_within 60 "zpool export -F with the send stopped" \
    zpool export -F $TESTPOOL
log_must test $within_rc -ne 0
log_must poolexists $TESTPOOL
log_must pool_has_failed $TESTPOOL
log_must pkill -CONT -f "[z]fs send $FS"
pin_export_failed
check_exit send
pin_kill_bg

pin_reimport

log_pass "zpool export -F frees a send, a receive and a diff blocked on" \
    "their pipes"
