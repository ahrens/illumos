#!/bin/ksh
# online.sh: an incremental receive into a mounted file system, with the pool
# failing in the txg of dmu_recv_end_sync(); then show what export -f does.
P=onpool; Q=onsrc; D=/var/tmp/online
zinject -c all >/dev/null 2>&1
for p in $P $Q; do zpool export -f $p >/dev/null 2>&1; zpool destroy -f $p >/dev/null 2>&1; done
rm -rf $D; mkdir -p $D/v $D/s
mkfile 1g $D/v/v1 $D/v/v2 $D/s/v
zpool create -f -o failmode=death $P $D/v/v1 $D/v/v2 || exit 1
zpool create -f $Q $D/s/v || exit 1
zfs create -o compression=off $Q/src
for i in 0 1 2 3; do dd if=/dev/urandom of=/$Q/src/f$i bs=1024k count=32 2>/dev/null; done
zfs snapshot $Q/src@s
zfs send $Q/src@s | zfs recv $P/dst || exit 1
dd if=/dev/urandom of=/$Q/src/f8 bs=1024k count=32 2>/dev/null
zfs snapshot $Q/src@s2
mount -p | grep $P
FAULT=""
for v in $D/v/v1 $D/v/v2; do FAULT="$FAULT zinject -d $v -e io -T write $P >/dev/null;"; done
for l in pad2 uber nvlist; do for v in $D/v/v1 $D/v/v2; do FAULT="$FAULT zinject -d $v -L $l $P >/dev/null;"; done; done
cat > $D/d <<EOF
#pragma D option quiet
#pragma D option destructive
#pragma D option strsize=2048
int fired;
fbt::dmu_recv_end_sync:entry
/!fired && stringof(args[1]->tx_pool->dp_spa->spa_name) == "$P"/
{
	fired = 1; system("$FAULT"); printf("fired\n");
}
fbt::zfs_resume_fs:return { printf("zfs_resume_fs returned %d\n", arg1); }
fbt::dounmount:return { printf("dounmount returned %d\n", arg1); }
fbt::zfs_umount:return { printf("zfs_umount returned %d\n", arg1); }
EOF
dtrace -s $D/d > $D/d.out 2>&1 &
dp=$!
sleep 3
for v in $D/v/v1 $D/v/v2; do zinject -d $v -D 500:16 $P >/dev/null; done
zfs send -i @s $Q/src@s2 | zfs recv -s $P/dst
echo "recv exited $?"
sleep 5
echo "--- mounts"; mount -p | grep $P
zinject -c all >/dev/null
echo "--- export -f"; zpool export -f $P; echo "export rc $?"
sleep 1
kill $dp; cat $D/d.out
echo "--- mounts after"; mount -p | grep $P
zpool list $P 2>&1 | tail -1
echo "--- import"
zpool import -d $D/v $P || exit 1
zfs list -r -t all -o name,receive_resume_token $P
tok=$(zfs get -H -o value receive_resume_token $P/dst)
echo "--- resume"; cat /$P/dst/* > /dev/null; sleep 6; zfs get -H written $P/dst
zfs send -nv -t $tok 2>&1 | tail -3
zfs send -t $tok > $D/resume.stream; echo "send rc $? size $(ls -l $D/resume.stream | awk '{print $5}')"
zstream dump $D/resume.stream 2>/dev/null | head -20 || zstreamdump < $D/resume.stream | head -20
zfs recv -sv $P/dst < $D/resume.stream; echo "recv rc $?"
