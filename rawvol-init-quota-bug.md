# stlouis#NNNN raw zvol initialization that runs out of space never retries a smaller block size

Seen as https://github.com/oxidecomputer/omicron/issues/11808 (a local storage disk that could not be deleted).

## Problem

A raw zvol's initialization picks a large block size, writes the whole volume, and only then looks for gang
blocks, restarting at half the block size if it finds any. Gang blocks take more space than the data in them
(about 16 KiB per ganged 1 MiB block with 4K sectors), more than the 4 MiB/GiB that sled-agent adds to a local
storage disk's quota. So on a fragmented pool, initialization can run out of quota before it ever checks for gang
blocks. It then fails with EDQUOT and keeps the space, so the volume never finishes initializing, and every later
open fails with ENOSPC.

## Fix

- When initialization runs out of space and some of what it wrote is gang blocks, free it and start over at a
  smaller block size, as when it finds gang blocks after writing the whole volume.
- When it runs out of space without gang blocks, or at the minimum block size, free what it wrote and fail
  (smaller blocks wouldn't help).
- Don't let a stop request hide an out-of-space error.
- Limit the block size estimate to the volume's minimum block size instead of asserting it.
- New test `zvol_raw_init_quota`.

## Not fixed

A volume can still be left unopenable if initialization is stopped partway through a pass (by `DKIOCRAWVOLSTOP`,
which sled-agent sends before destroying a volume, or by a panic, reboot or power loss) after the gang overhead in
the part already written has used up the quota's slack. The space written so far stays allocated. On the next
open, the space check before initialization resumes finds less space available than the rest of the volume needs,
and the open fails with ENOSPC before initialization can free anything or retry. Until this is fixed, the way out
is to clear the parent's quota and reservation, then open the volume and destroy it.

Possible fixes:

- When the space check fails and part of the volume is already initialized, free what was written and start over
  (perhaps at a smaller block size) instead of failing the open.
- Skip the space check when part of the volume is already initialized, and let initialization resume; when it
  runs out of space, the handling added here frees what was written, and retries at a smaller block size if some
  of it is gang blocks.

## Reproducing

Force gang blocks for allocations over 64K (`metaslab_force_ganging`), and create a 256 MiB raw zvol in a
filesystem with quota and reservation set to the volume size plus 4 MiB/GiB, on 4K-sector disks. Without the fix,
initialization tries 16M, 8M, 4M and 2M blocks (gang blocks each time), then fails with EDQUOT at 1M, with the
volume still using all the space:

```
NAME            USED  AVAIL      QUOTA
rvq/p      269627392      0  269484032
dd: /dev/zvol/rdsk/rvq/p/vol: open: No space left on device
```

## Testing

Oxide rack VM (Helios, 8 vCPU, 32 GiB, three 32 GiB local disks with 4K sectors), DEBUG builds of stlouis
f0b2e4d3e4 and of this change.

| Build | Test | Result |
|---|---|---|
| stlouis | repro above | 4/4 EDQUOT, space kept, open fails |
| stlouis | `zvol_raw_init_quota` | 3/3 FAIL (initialization failed: EDQUOT) |
| this change | repro above | 2/2 succeed at 64K blocks; with a 128K minimum, EDQUOT with 56 KiB used, and the volume reopens |
| earlier revision of this change (retried on any out-of-space error) | out of space without gang blocks (below) | EDQUOT after 12 passes (16M down to 8K), 57 s |
| this change | out of space without gang blocks (below) | EDQUOT after 1 pass, 1 s, space freed |
| this change | `zvol_raw_init_quota`, `zvol_raw_open_enospc`, `zvol_raw_init_open`, `zvol_raw_init_stall` | 5/5 PASS each |
| this change | all `zvol` ZTS groups | 34/34 PASS |

Running out of space without gang blocks isn't covered by a test: the open's space check rejects a quota that is
too small from the start, and a quota that is short only by metadata gets overshot rather than returning EDQUOT, so
it takes something else using space during initialization, which is racy. It was checked by hand with
`copies=2`, which stlouis applies to a raw zvol's zero-filled writes but the open's space check ignores: a 256 MiB
raw zvol with `copies=2`, in a filesystem with quota and reservation set to the volume size plus 4 MiB/GiB, runs
out of space about halfway through its first pass.
