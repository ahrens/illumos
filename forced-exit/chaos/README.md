# Chaos harness

`chaos.sh` fails a pool at a random moment while a mixed kernel workload runs on it, exports the pool with the workload still attached, imports it again, and checks what forced exit promises. It repeats this for a given number of iterations, draws each iteration's configuration from a logged seed, and stops at the first failure.

ztest runs forced exit only in libzpool. On a DEBUG kernel, the harness reaches what ztest can't: the ZPL (`fsync()`, `O_DSYNC`, `mmap`, directory fsyncs, `.zfs/snapshot`, online receives), volumes, `vdev_disk` and devices that disappear, the `zpool` and `zfs` ioctls, streams blocked on pipes, encryption keys, the export of a busy pool, and FMA. Where each ZTS test sets up one such scenario, the harness runs them together and fails the pool at a random point in its txg sync. Most of the bugs it found (see Results) were panics or DEBUG assertion failures in code that ztest doesn't reach.

## Files

| File | Role |
| --- | --- |
| `chaos.sh` | The harness. Run it with `ksh`. |
| `chaos.d.tmpl` | The D script, written to `$CHAOS_DIR/chaos.d` with the pool name filled in. |
| `writer.py` | Writes 128K records (`fsync`, `O_DSYNC` or raw volume), logs each acknowledged one, and holds its descriptor after its first error. |
| `verify.py` | Checks the writers' logs: `durable` (every acknowledged record is on disk) and `afterfail` (no acknowledged record started after the failure). |
| `mmap_hold.py` | Dirties every page of a shared mapping and holds it. |
| `poller.py` | Runs and times the `zpool` and `zfs` commands that sled-agent polls. |
| `throttle.py` | Rate-limits a pipe, so that streams are still running when the pool fails. |
| `overlap.py`, `reuse.py` | Report suspicious space reuse in the allocation trace. |
| `acts/act_*.sh` | Activity modules, each with an embedded Python helper. |
| `zinject-check.sh` | A standalone helper that `chaos.sh` doesn't use. It checks `zinject`'s `io-prefail`, `noop` and `corrupt` error types on a two-way file mirror (pool `zicheck`). |
| `online.sh` | A standalone helper that `chaos.sh` doesn't use. It fails a pool in the txg of `dmu_recv_end_sync()` during an online incremental receive, then exports, imports and resumes (pools `onpool` and `onsrc`). The onlinerecv activity covers the same ground. |

## Requirements

- An illumos VM running a DEBUG build of this branch that you don't mind panicking, which is how most bugs show up. `chaos.sh` exits at once if `zinject` lacks `-e io-prefail`. It reads `spa_t`'s `spa_exit` with mdb (`SPA_EXIT_FAILED` is 2) and probes `spa_fail()`.
- root, `ksh` (ksh93), `nawk`, `mkfile`, `pstack`, `mdb -k` and `mdb -kw`, DTrace's `fbt` provider, and `python3` with `ctypes` (the asyncdestroy activity calls `libzfs_core.so.1`).
- No spare disks. Every vdev is a 1 GB file in `$CHAOS_DIR/vdev` (the bystander's is `$CHAOS_DIR/ok/v`), used directly or through lofi, and each iteration recreates four of them. `/var/tmp` needs 3 GB free (see Quirks); it belongs to the boot environment, so install the harness again after booting another one.
- No existing pool named `$CHAOS_POOL` or after its bystander (`chaosok` by default).
- A dump device with savecore enabled.
- `set mod_uninstall_interval=31536000` in `/etc/system`, then a reboot. Without module autounload, an illumos DTrace race that can panic a system with `fbt` probes enabled can't happen (FE24).
- fmd running, on a system where fmd's history doesn't matter (see Quirks).

## Running

Copy the directory to the VM, and start the run there as root:

```
scp -r forced-exit/chaos root@<vm>:/var/tmp/chaos-helpers
```

```
CHAOS_HELPERS=/var/tmp/chaos-helpers CHAOS_DIR=/var/tmp/chaos CHAOS_POOL=chaospool nohup ksh /var/tmp/chaos-helpers/chaos.sh 1000 > /var/tmp/chaos.nohup 2>&1 &
```

The argument is the number of iterations (default 50), each about a minute long. Follow `$CHAOS_DIR/chaos.log`; a finished run ends with `CHAOS DONE`. Before a long run, run one iteration with `CHAOS_FORCE=act_asyncdestroy=1,act_crucible=1,act_dwell=1,act_keyrotate=1,act_nschurn=1,act_onlinerecv=1` to catch a broken environment. `CHAOS_WEDGE_S=0` sends almost every iteration whose trigger isn't `F` (which starts no watchdog) down the wedge path, which tests the watchdog; a failmode=death iteration then fails, as it should.

Nothing times out a hang outside the window from the trigger to the export, or in the export itself (the watchdog is stopped first): an import, export, scrub or `zdb` that never returns stalls the run silently. The campaigns alerted when `chaos.log` went 30 minutes without a new iteration.

## Environment variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `CHAOS_HELPERS` | `/var/tmp/chaos-helpers4` | The directory holding the files above. The default is stale; always set it. |
| `CHAOS_DIR` | `/var/tmp/chaos` | Working and output directory. |
| `CHAOS_POOL` | `chaospool` | The pool under test. The bystander's name replaces a trailing `pool` with `ok` (`chaosok`), or appends `ok`. |
| `CHAOS_SEED` | seconds since the epoch, mod 100000 | The run seed. Iteration i seeds ksh's `RANDOM` with seed × 1000 + i. |
| `CHAOS_FORCE` | none | Comma-separated `key=value` overrides of the draws, such as `failmode=death,trigger=wfail,act_crucible=1`. The asyncdestroy activity also takes `ad_throttle=N` (0 for unthrottled) and `ad_flush=0\|1`. |
| `CHAOS_ACTS` | all | Comma-separated activities to load; the others never run. |
| `CHAOS_WEDGE_S` | 30 | How long a probe of the bystander may block before the watchdog calls it a wedge. |

## Stopping

`touch $CHAOS_DIR/STOP` stops the run after the current iteration. After the last iteration, a failure or a stop, the run kills its background processes, clears its pool's injections, runs `zpool export -F` if the pool is still imported, destroys the bystander, detaches the lofi devices, and logs counts of the draws and DTrace buckets.

Killing `chaos.sh` leaves the iteration behind. To clean up by hand: kill `writer.py`, `mmap_hold.py`, `poller.py`, `throttle.py`, the `act_*.py` helpers, `vsleep`, `zfs send` and `zfs recv`; clear the pool's injections (`zinject -c <id>`), since a failed pool's export waits for them (if a wedge blocks `zinject`, export with `-F` first); `zpool export -F chaospool`; `zpool destroy -f chaosok`; `lofiadm -d` the lofi devices of `$CHAOS_DIR/vdev/v1`, `v2` and `v3`; and reset the asyncdestroy tunable (see Quirks).

## One iteration

A check that fails records the result code given in parentheses.

1. Draw the configuration. `CHAOS_FORCE` can set any key.

| Key | Values and weights |
| --- | --- |
| `shape` | `file3` 50 (three file vdevs, striped); `lofi1` 25, `lofi3` 25 (one or three lofi devices over the files, through `vdev_disk`, with `ashift=12` like an Oxide U.2 pool) |
| `failmode` | `death` 70, `wait` 15, `continue` 15 |
| `trigger` | file3: `wfail` 55, `afail` 20, `F` 25; lofi: `wfail` 40, `afail` 15, `F` 20, `vanish` 25 |
| `resolve` | `F` for a wait or continue pool whose trigger isn't `F`, otherwise `-` |
| `export` | `-f` 50, `plain` 25, `-F` 25; always `-F` when the trigger or the resolve is `F` |
| `dup` | 0 80, 1 20: run a second, concurrent `zpool export` |
| `act_NAME` | 0 50, 1 50 for each loaded activity |

2. Check free space and fmd's error log (see Quirks), and look for `STOP`.
3. Build the pools. The pool under test holds `fs`; `data` (128 MB of files, snapshot `@s`); `crypt` (aes-256-gcm with a raw key, like Oxide's crypt dataset) and `crypt/zone`; `vol` (256 MB, volblocksize 128K, so that its log records use `dmu_sync()`); a file to map; and a copy of `/usr/bin/sleep`. The bystander pool holds `src` (128 MB, `@s`). Then the drawn activities' setups run; a failure stops the run with `SETUP FAILED` and no CSV row.
4. Start DTrace, which must print `ready` within 120 s (`dtrace`).
5. Start the workload and the drawn activities. The workload: `fsync` and `O_DSYNC` writers in `fs`, and `O_DSYNC` writers in `crypt/zone` and on the raw volume, all logging each acknowledged record; a dirty shared mapping; the copied `sleep` running from the pool; a cwd in `data/.zfs/snapshot/s` and a reader there; resumable sends between the two pools in both directions, throttled to 30 MB/s; snapshots created and destroyed; `poller.py`; and a scrub. The holders keep their descriptors, mappings and cwds until they are killed after the export.
6. Sleep 0 to 5 s (`ms`), and start the wedge watchdog unless the trigger is `F`.
7. Trigger the failure. `wfail`: on every leaf, `zinject -e io-prefail -T write`, which fails each write other than a label or repair write before it reaches the device, plus label faults (`-L pad2`, `uber` and `nvlist`) so that label and uberblock writes fail too (they still reach the device: a label fault sets the error when the write completes). `afail`: the same with `-T all`. `vanish`: `lofiadm -f -d` every lofi device. `F`: `zpool export -F` of the busy pool.
8. Unless the trigger was `F`, a death pool must reach `SPA_EXIT_FAILED` within 60 s (`nofail`), and a wait or continue pool must suspend within 60 s (`nosuspend`); after 0 to 3 s suspended, the harness stops the watchdog, clears the injections, and runs `zpool export -F` (the resolve).
9. Within 20 s every writer must log an error, or the volume writer have filled the volume (`noerr`). In odd iterations the mapping process is killed at this point, so that its dirty pages are dropped while the failed pool is imported (unless the trigger or the resolve has exported it already); in even ones, after the export.
10. Stop the watchdog. Unless the pool is already exported, clear its injections and export it with the drawn flag (and the duplicate, if drawn). The export must return 0 within 60 s (`export`) and print nothing (`exportwarn`); within 15 s every stream must have exited (`streams`), and nothing of the pool may be mounted (`mounted`). The holders are then killed and must be gone within 10 s (`holders`), and the volume's `/dev/zvol` node 5 s after that (`minor`). No polled command may have taken more than 30 s unless the iteration wedged (`poll`).
11. Stop DTrace and check its trace: no `FENCE` line (`fence`), and no writer record that started after `spa_fail()` acknowledged (`afterfail`). Save the remaining ZFS kernel stacks if any is in `spa_exit*`, `zil_commit`, `dmu_send*`, `dmu_recv*`, `zvol_*` or `txg_wait*`.
12. Check the disks (a lofi pool through `/dev/lofi` again). The uberblock must be at `spa_ubsync`'s txg as of `spa_fail()`, or at the next one if the pool failed after that txg's uberblocks landed but before its labels did (`ub`). In the logs the import would claim (of `fs`, `vol`, `crypt/zone`, `crucible/r0` and `crypt/nschurn`), no two block pointers born after the on-disk uberblock's txg may share a DVA (`DVA[0]`), since `zil_claim()` would panic on them (`dupdva`).
13. `zpool import -N` (`import`), load `crypt`'s key, and `zfs mount -a`, which replays the logs. Every acknowledged writer record must read back intact (`lost`). Then come the activities' verifies (`act`), a scrub with no errors (`scrub`), a plain export (`export2`), a clean `zdb -e -bcc` (`zdb`), an import (`import2`), and the destruction of both pools, retried for 10 s because fmd and sysevent handlers can hold a just-imported pool briefly (`destroy`).

## Wedges

From just before the trigger until the export, the watchdog runs `zpool list` on the bystander pool about once a second. That takes `spa_namespace_lock`, so a probe blocked for `CHAOS_WEDGE_S` seconds means that a thread sleeps on the failing pool while holding it. The watchdog saves `::stacks -m zfs` (`wedge.stacks`, kept in `wedge.<iter>/`) and runs `zpool export -F`, which fails the pool without that lock and so must release every such sleeper (the export itself may return EBUSY, since the injection handlers are still there).

A wedge fails the iteration (`wedge`) if the pool is failmode=death, which never suspends and so should leave nothing asleep on it, or if the watchdog's `zpool export -F` and the probe haven't both returned 90 s after the harness goes to stop the watchdog. A released wedge on a wait or continue pool is the known upstream wedge (see Known benign outcomes): the iteration skips the `poll` check and passes with result `wedge`, logged as `iter N ok (wedge)`.

## Activities

Each `acts/act_NAME.sh` defines `act_NAME_setup`, `act_NAME_start` and `act_NAME_verify`. Verify runs after the import and prints one line to `chaos.log`; a nonzero status fails the iteration (`act`) and copies every activity's `$CHAOS_DIR/act_*` files to `fail.<iter>`. Each file's header comment states the ZFS rules its checks rely on. A crucible, nschurn or onlinerecv verifier that breaks or reaches no verdict says so and the iteration passes; a broken keyrotate verifier fails it.

| Activity | Workload | Verify |
| --- | --- | --- |
| crucible | A region like a Crucible downstairs (no compression, 128K records, a reservation and a quota, usually `primarycache=metadata`) with eight extent files and a snapshot `@base`. Two writers follow Crucible's raw-extent protocol (dirty byte, context slots, fsyncs, periodic flushes) without `O_DSYNC`, so their writes become `WR_NEED_COPY` records, often split across log blocks. A loop takes snapshots, and a reader checks `@base`. | No read returned wrong data; no fsync that started more than 200 ms after the failure returned 0; every block is whole, at least at its acknowledged generation, and consistent with its context slot and the extent's metadata; acknowledged snapshot creates and destroys hold; `@base` and the newest four snapshots hold what they should. |
| asyncdestroy | Destroys a snapshot and then its dataset (up to 80 MB in 4K records) through `libzfs_core`, because `zfs destroy` reports success when the ioctl fails with ENOENT. Most iterations throttle the background free with the global `zfs_async_block_max_blocks`, and half flush the ARC first. | A destroy that returned 0 is gone; a surviving dataset references what setup recorded; the frees drain within 60 s and nothing leaks. |
| dwell | Like sled-agent halting a failed pool's zones before the export: three holders with files, mappings and cwds in the pool (a zone root in an encrypted dataset; a Crucible-like process whose unlinked open file makes its close run `zfs_rmnode()`; a Propolis-like process whose close is a volume's last close) get SIGTERM once `spa_exit` shows the pool failed. | Every holder was gone 10 s after its SIGTERM (otherwise its stacks are saved), and setup's datasets exist. |
| keyrotate | One loop rotates `crypt`'s key as Omicron does (`zfs change-key` to a new raw key file, setting `keylocation` and `oxide:epoch`); another creates encryption roots `crypt/krN`, mounts some with an fsynced file, makes some inherit `crypt`'s key, and destroys them. | `crypt`'s epoch lies between the last acknowledged rotation and the last one tried, and its `keylocation` names that epoch's key, which is loaded and decrypts it; `crypt` and `crypt/zone` mount; each `krN` matches its acknowledged commands; nothing that started after the failure returned 0. |
| nschurn | Namespace churn with directory fsyncs, as Pebble and Crucible's extent repair do, in `fs` and in the encrypted `crypt/nschurn`: file writes, fsyncs and renames, links, symlinks, chmods, directory renames, unlinks of open files, and a WAL. Setup checks the verifier's model on the healthy pool. | Every operation that a directory fsync acknowledged is there; a file's content is checked once its own fsync returned 0, or once a directory fsync after its rename did (logging a rename moves the file's pending writes to the synchronous list); no name appears that was never created; the WAL holds every acknowledged record and ends at a record boundary; no fsync that started more than 1 ms after the failure returned 0. |
| onlinerecv | Receives incrementals (with `-e`, `-c`, both or neither) into, and rolls back, the mounted file system `online` while a holder keeps files open there and in `.zfs/snapshot`, so that the pool fails between `zfs_suspend_fs()` and `zfs_resume_fs()`, in a receive's data phase, or in a sync task. | `online` mounts; its snapshots, guids and contents match the acknowledged operations; nothing that started after the failure returned 0; a resume token resumes or aborts cleanly; the reader never saw bytes that no version of the file had. |

## Output

Everything goes to `CHAOS_DIR`. Passing iterations reuse the same files.

- `chaos.log`: the run seed; per iteration, an `iter N ok: <choices>, ...` line with timings and txgs, or a failure line `iter N: <MESSAGE> (evidence in <dir>/fail.N; seed <seed>, <choices>)`; activity lines and notes; setup and import output; and the end-of-run counts.
- `chaos.csv`: one row per finished iteration, including the failing one. `buckets`: the `BUCKETS` lines behind the counts.
- `d.out`, the DTrace trace, on the clock of the Python helpers' `time.monotonic_ns()`: at the first `spa_fail()`, `spa_fail <ns>`, `UBSYNC <txg>` and a `BUCKETS` line (the sync phase, such as `dsl_pool_sync-pass2` or `labels`, and whether a send, receive, `zil_commit()`, `dmu_sync()` or volume write was in progress); `FENCE` lines with stacks; allocation lines for `overlap.py` and `reuse.py`; and the `zil_commit()` returns of every Python process, the writers' and the activities' (`zc <pid> <ns> <rc>`). DTrace drops, noted in `chaos.log`, can hide what these checks look for.
- The writers' `w0.log`, `w1.log`, `w2.log` and `zv.log` (one `<record> <start ns> <end ns>` per acknowledged record, then `err <errno> <ns>` or `full <ns>`); `poll.log` (`<start ns> <ms> <rc> <command>`); `export.err` and `export2.err`; `zil3-*.out` (the logs to claim, before the import); `zil.out` (`fs`'s log as the import found it); `zdb.out`; and `act_*`.
- `fail.<iter>/`: those files, the wedge and destroy files, `dtrace-late` (if dtrace didn't start), `stacks.zfs`, `stacks.all` and `ps`.
- For passing iterations worth a look: `wedge.<iter>/`, `stuck.<iter>/` (suspect stacks after the export), `overlap.<iter>/`, `reuse.<iter>/`, `notrace.<iter>/` (no `spa_fail` line, so the checks that need it were skipped) and `destroy-busy.<iter>/`.

| CSV column | Meaning |
| --- | --- |
| `iter`, `seed` | Iteration and its seed. |
| `shape`, `failmode`, `trigger`, `resolve`, `export` | The draws. |
| `ms` | Delay before the trigger. |
| `phase` | Sync phase at `spa_fail()`, or `NOTRACE`. |
| `ub`, `ubsync` | On-disk uberblock txg, and `spa_ubsync`'s txg at the failure. |
| `export_s` | Seconds the export took (0 if the watchdog's export did it). |
| `fence` | `FENCE` lines. |
| `poll_max_ms` | The slowest polled command. |
| `acked` | Acknowledged records of `w0/w1/w2/zv`. |
| `zfs_threads`, `suspect` | ZFS kernel stacks left after the export, and their lines in the functions listed in step 11. |
| `acts` | The activities that ran, joined with `+`. |
| `result` | `ok`, `wedge`, or a result code from One iteration. |

## Triaging a failure

`grep -c ',ok$' chaos.csv` and `grep -c ',wedge$' chaos.csv` count the passes. A `wedge` row is a failure only when it is the run's last row and `chaos.log` says `WEDGE NOT RELEASED` or `A DEATH POOL WEDGED`.

1. Read the failure line near the end of `chaos.log`, before the end-of-run counts. An activity's reason is in its own line just above, with details in `act_NAME.*`.
2. Build the timeline from `d.out` against the writers' and activities' logs, which use the same clock.
3. `stacks.zfs`, `stacks.all` and `ps` show where everything was when the failure was detected.
4. The vdev files stay in `$CHAOS_DIR/vdev` until the next setup, so the exported pool can be imported for a post-mortem: `zpool import -N -d $CHAOS_DIR/vdev chaospool`, or, for a lofi shape, `lofiadm -a` each of `v1`, `v2` and `v3` (`lofi1` uses only `v1`) and import with `-d /dev/lofi`.
5. To aim more iterations at the same configuration, set `CHAOS_FORCE` to the logged choices, replacing `acts=`, which isn't a key, with `act_NAME=1` for each activity it lists and `act_NAME=0` for the others. The timing isn't reproducible.

A panic stops the run with no failure line, leaving the current iteration's files in `CHAOS_DIR`. In the dump, `::dtrace_state` lists DTrace consumers, and `<address>::dtrace` prints trace data that `d.out` didn't receive. After the reboot, `zpool.cache` can bring back the pool and its bystander; export the one and destroy the other before starting again, or setup fails with "pool already exists".

## Known benign outcomes

Wedges on wait and continue pools, about once per 1,000 iterations. A scrub finishes just before the failure, and `dsl_scan_done()` requests `SPA_ASYNC_RESILVER_DONE`. The pool suspends inside `spa_sync()` holding `SCL_CONFIG` as reader; the async thread's `spa_vdev_resilver_done()` waits for `SCL_ALL` as writer; and the next `zpool list` or `zpool status` queues behind it while holding `spa_namespace_lock`, which blocks every later pool command, `zinject` and `zpool clear` included. `wedge.stacks` shows `spa_vdev_resilver_done()` and the blocked `spa_open_common()` callers. This is upstream behavior that the branch doesn't change (see DESIGN.md, Export and unload): a death pool fails rather than suspends, and `zpool export -F` releases the wedge (FE19).

Also expected, and only noted in `chaos.log`: a `zpool destroy` that was busy at first; a dwell holder that died before its SIGTERM, from SIGBUS on a mapping of the failed pool; a broken verifier (`VERIFY BROKE`, `NOT CHECKED`, `INCONCLUSIVE`), which is a harness bug; and an unconfirmed write of the asyncdestroy tunable. `ALLOCATION OVERLAP`, `OPEN-CONTEXT REUSE` and `stuck.<iter>` don't fail an iteration, but are worth reading.

## Quirks

- `CHAOS_HELPERS` defaults to `/var/tmp/chaos-helpers4`, a stale path. The harness reads its helpers from `CHAOS_HELPERS`, not from the directory `chaos.sh` is in, so always set it.
- The check at the start of each iteration (`guard()`) stops the run when `/var/tmp` has less than 3 GB free, whatever `CHAOS_DIR` is. When `/var/fm/fmd/errlog` passes 200 MB, it rotates the log and deletes every rotated `errlog.*` file.
- A run that stops at a failure after the asyncdestroy setup throttled the tunable and before its stream restored it (while the stream still runs, or at a later activity's setup or the DTrace start) leaves the global `zfs_async_block_max_blocks` throttled for every pool: the stream and verify restore it, but `chaos.sh` doesn't at the end of a run. Reset it with `echo zfs_async_block_max_blocks/Z 0xffffffffffffffff | mdb -kw`.
- `chaos.log` and `chaos.csv` are appended to, and every run numbers its iterations from 1, so move `CHAOS_DIR` aside before starting another run in it.
- A `d.out` with more than one `BUCKETS` line splits that iteration's CSV row, since `phase` takes a value from each line.
- `chaos.sh` clears only its own pool's injections, but `zinject-check.sh` and `online.sh` run `zinject -c all`, which clears every pool's, so don't run them on a host while `chaos.sh` runs.
- The headers of `act_crucible.sh` and `act_nschurn.sh` wrongly say that the duplicate-DVA scan skips their datasets.

## Results

On a DEBUG build whose kernel and library code is identical to the branch tip (only test files differed), two 1,000-iteration runs finished with no failures and one released wedge each, both of the known kind on failmode=wait pools: 2,000 iterations in all. A third 1,000-iteration run on the same build is in progress.

Earlier campaigns on intermediate builds of the branch found these issues. Each is fixed on the branch unless noted; the commit map in `forced-exit/README.md` gives the fixing commit for each tracker ID.

- A failed `dmu_sync()` write's space was reused in its txg by another dataset's log block while an lwb pointed to it, so the import panicked in `zil_claim()` or lost acknowledged writes (FE6).
- Listing snapshots on a failed pool panicked in `dsl_dataset_get_remap_deadlist_object()` when a snapshot's ZAP couldn't be read (FE14).
- A forced unmount raced `zfs_inactive()`'s page push into the log and panicked in `zil_close()`; a forced destroy on a chaos VM hit it, outside an iteration (FE16).
- `zfs_get_data()` asserted that reading back an immediate write's data succeeds, which on a failed pool it doesn't (FE18).
- The wedge under Known benign outcomes (FE19). Not fixed; `zpool export -F` releases it.
- A plain export after `zpool scrub -w` panicked in `dsl_scan_fini()` on a non-empty scan prefetch queue (FE20; OpenZFS d6496040d9).
- A race in `dsl_dir` parent space accounting panicked a healthy pool (FE21; OpenZFS 2eae71cd17).
- A pool that failed during an async destroy panicked on EIO from iterating the free bpobj (FE22).
- Opening, listing or getting properties of a volume whose dnode block couldn't be read (with an error other than EIO) panicked after `zvol_get_stats()` (FE23).
- An illumos DTrace race between `fbt_destroy()` on module autounload and `fbt_invop()` panicked a VM running the harness's probes (FE24). Not a ZFS bug and not fixed; the `/etc/system` setting under Requirements avoids it.
- An online receive panicked in `zfs_resume_fs()` when it couldn't read the file system's properties (FE25).
- `zpool export -F` left a detached file system mounted while a lookup held the covered vnode's lock (FE26).
- zfs-diagnosis leaked a pool handle per ZFS ereport, until fmd grew to about 4 GB and aborted (FE27).
- zfs-diagnosis faulted a device of a re-imported pool for errors from before the import, so the plain export after the scrub failed with EBUSY (FE29).
- `zfs` and `zfs recv` abort on ECKSUM, because illumos libzfs has no `EZFS_CKSUM` (OpenZFS 6c8e9f09c2); this showed once the FE23 and FE25 fixes returned errors instead of panicking (FE45). Not fixed on the branch.

Two more fixes the campaigns led to are in the stlouis base: illumos 18569 (OpenZFS 904d4327f4: `dmu_objset_open_impl()` freed an objset with its property callbacks still registered) and illumos 18581 (OpenZFS c33a55b0c2: `dsl_deadlist_open()` returns errors).
