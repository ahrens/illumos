#!/bin/ksh
#
# zinject-check.sh: check the ported zinject error types on a mirror of two
# file vdevs.
# - io-prefail: writes to v1 fail and never reach the file (DTrace sees no
#   vdev_file_io_start write to v1 outside its labels, except repair writes,
#   which io-prefail lets through as upstream does); the mirror carries on,
#   and a scrub repairs v1.
# - noop: writes to v1 "succeed" without reaching it; a scrub then finds
#   and repairs the stale copy.
# - corrupt: reads from v1 come back with a bit flipped; the mirror repairs
#   them and v1 counts checksum errors.
#
P=zicheck; D=/var/tmp/zicheck; V1=$D/v1; V2=$D/v2
fail() { echo "FAIL: $*"; zinject -c all >/dev/null 2>&1; exit 1; }
labels_excluded_md5() # file: md5 of the data area (skip 4 MB front, 512 KB back)
{
	dd if=$1 bs=512k skip=8 count=$((256 * 2 - 8 - 1)) 2>/dev/null | digest -a md5
}
zinject -c all >/dev/null 2>&1
zpool destroy -f $P >/dev/null 2>&1
rm -rf $D; mkdir -p $D; mkfile 256m $V1 $V2
zpool create -f $P mirror $V1 $V2 || fail create
zfs create -o recordsize=128k -o compression=off $P/fs
dd if=/dev/urandom of=/$P/fs/a bs=1024k count=32 2>/dev/null
zpool sync $P

echo "== io-prefail"
dtrace -q -n '
fbt::vdev_file_io_start:entry
/args[0]->io_type == 2 && stringof(args[0]->io_vd->vdev_path) == "'$V1'" &&
    args[0]->io_offset >= 4194304 &&
    args[0]->io_offset < args[0]->io_vd->vdev_psize - 524288/
{ @[(args[0]->io_flags & 2) ? "repair" : "other"] = count(); }
END { printa("v1 data writes issued: %s %@d\n", @); }' > $D/d.out 2>&1 &
dpid=$!
sleep 3
zinject -d $V1 -e io-prefail -T write $P || fail "zinject io-prefail"
dd if=/dev/urandom of=/$P/fs/b bs=1024k count=32 2>/dev/null
zpool sync $P
sleep 1
zinject -c all >/dev/null
kill -TERM $dpid; wait $dpid
cat $D/d.out
grep -q "issued: other" $D/d.out && fail "io-prefail writes reached v1"
zpool status $P | grep v1
zpool clear $P; zpool scrub -w $P
zpool status -v $P | grep -q "No known data errors" || fail "scrub after io-prefail"
echo "io-prefail OK"

echo "== noop"
zpool clear $P
zinject -d $V1 -e noop -T write $P || fail "zinject noop"
dd if=/dev/urandom of=/$P/fs/c bs=1024k count=32 2>/dev/null
zpool sync $P
zinject -c all >/dev/null
zpool status $P | grep v1
zpool scrub -w $P
zpool status $P | grep -E "v1|scan:|repaired"
zpool status -v $P | grep -q "No known data errors" || fail "scrub after noop"
zpool status -p $P | nawk -v v=$V1 '$1 == v && $5 + 0 > 0 { found = 1 } END { exit !found }' ||
    fail "noop: the scrub found nothing stale on v1"
echo "noop OK"

echo "== corrupt"
zpool clear $P
zpool export $P && zpool import -d $D $P || fail "reimport"
zinject -d $V1 -e corrupt -T read -f 100 $P || fail "zinject corrupt"
zpool scrub -w $P
zinject -c all >/dev/null
zpool status -p $P | grep -E "v1|v2"
zpool status -p $P | nawk -v v=$V1 '$1 == v && $5 + 0 > 0 { found = 1 } END { exit !found }' ||
    fail "corrupt: no checksum errors on v1"
zpool status -v $P | grep -q "No known data errors" || fail "corrupt: data errors"
echo "corrupt OK"
zpool destroy $P; rm -rf $D
echo "ALL OK"
