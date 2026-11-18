# Forced export and failmode=death: review guide

## What this is

This branch lets a ZFS pool fail rather than suspend, so that a dead drive costs one pool instead of the whole system. A pool with the new `failmode=death` fails wherever it would otherwise suspend; `zpool export -F` fails a writable pool of any failmode, in any state, before exporting it; and a reboot arms every writable pool, so that one that suspends during shutdown fails rather than hanging the reboot. A failed pool writes nothing more to its disks, the threads waiting on it return (`fsync()` with `EIO`), its health is FAILED, and FMA diagnoses it as ZFS-8000-LR. `zpool export` removes it without affecting other pools, and it imports again later at its last synced txg, with acknowledged synchronous writes replayed from the intent log. The intended user is sled-agent, which manages the single-drive U.2 pools on Oxide sleds. `DESIGN.md` in this directory describes the design at the tip of the branch.

The tracker IDs below and in DESIGN.md (FE19, PT1, ...) are from Matt's local ZFS issue tracker, which reviewers can't read; Matt can supply any entry.

The branch is `agents/forced-exit` (`forced-exit` on github.com/ahrens/illumos): 91 commits on stlouis `d9acef1b04`, ending at `a487a3e47f`, plus two commits that add this directory as a review aid. Drop both before the branch integrates.

## How the branch is organized

The branch is ordered so that it can land in pieces. Commits 1-60 stand on their own: OpenZFS ports and fixes for bugs that exist without the feature. Each can go upstream ahead of the feature, and drops out of the branch at the first rebase after its upstream version reaches stlouis. The feature starts at 61, whose subject begins with ☠️ (no earlier commit uses `spa_failed()` or `failmode=death`), followed by its ZTS commits and then by fixes whose code or tests need it.

In the tables, # counts from the base and hashes are as of `a487a3e47f`. Change-Id is the first nine characters after the leading I; it survives rebases, and `git log --grep 'Change-Id: I<prefix>'` finds the commit. Subjects omit the placeholder bug ID (`stlouis#XXXX`, `XXXXX` or `NNNNN`). In the status column, CR is a review on code.illumos.org, # an OpenZFS pull request or issue, and "not filed" means no upstream bug or review exists yet.

### Suspend foundation (1-9)

| # | commit | Change-Id | subject | tracker | upstream status |
|---|---|---|---|---|---|
| 1 | 6c419efa94 | ccd356ebf | txg: generalise txg_wait_synced_sig() to txg_wait_synced_flags() | PT1 | OpenZFS a7de203c86; illumos port prepared, not filed |
| 2 | aa504bbf64 | 637eae6a4 | dmu_tx: rename dmu_tx_assign() flags from TXG_* to DMU_TX_* | PT1 | OpenZFS f69631992d; illumos port prepared, not filed |
| 3 | 4a98d4fd46 | f89922e8c | txg_wait_synced_flags: add TXG_WAIT_SUSPEND flag to not wait if pool suspended | PT1 | OpenZFS 468d22d60c; illumos port prepared, not filed |
| 4 | b1d7403e3a | 755ff1077 | dmu_tx: make DMU_TX_* flags an enum | PT1 | OpenZFS ac2e579521; illumos port prepared, not filed |
| 5 | 6a1c7bdf63 | abb302b8b | dmu_tx: break tx assign/wait when pool suspends | PT1 | OpenZFS 4653e2f7d3; illumos port prepared, not filed |
| 6 | 65997680f8 | 4f4762785 | dmu_tx_assign: make all VERIFY0 calls use DMU_TX_SUSPEND | PT1 | OpenZFS 55d035e866; illumos port prepared, not filed |
| 7 | 39b3e7d4f4 | e39482991 | dmu_tx_assign: DMU_TX_NOWAIT callers busy-loop while the pool is suspended | PT1 | Oxide; OpenZFS fixed the same bug in 2a963979a0, which the prepared illumos port carries instead |
| 8 | eae5bdbc9c | edecad397 | zio_resume: log when unsuspending the pool | PT1 | OpenZFS 8be2f4c3d2; illumos 18756 filed, CR 5305 |
| 9 | 6898464650 | 4264e235f | add ZFS tests for dmu_tx behaviour when the pool suspends | PT1 | tests from OpenZFS 2303775fea plus Oxide tests; illumos port prepared, not filed |

### Export and the namespace lock (10-18, 37)

| # | commit | Change-Id | subject | tracker | upstream status |
|---|---|---|---|---|---|
| 10 | 0be7ac246d | 54eeb388f | zpool export of a suspended pool blocks every zpool command | FE33 | Oxide; not filed |
| 11 | 307b3f6a37 | d5edc4de9 | Add the '-a' option to 'zpool export' | PT5 | OpenZFS 859735c095; illumos port prepared, not filed |
| 12 | bcb13c98c9 | 97bab81a7 | Parallel pool import | PT5 | OpenZFS c183d164aa; illumos port prepared, not filed |
| 13 | 5b23f6aeda | 09cfa0d73 | Race condition between spa async threads and export | PT5 | OpenZFS 43a8536260; illumos port prepared, not filed |
| 14 | c6f3201d16 | 6589324a3 | Add support for parallel pool exports | PT5 | OpenZFS 975a13259b + 89acef992b; illumos port prepared, not filed |
| 15 | eba07aabde | 8df4a1299 | Avoid dirtying the final TXGs when exporting a pool | — | OpenZFS 2fb52853dc; not filed |
| 16 | 3cceeff65b | 411ee8b9d | zpool status hides a suspended pool that is resilvering | FE34 | Oxide; not filed |
| 17 | db71595cfa | 5340712a4 | ztest: spa_destroy() can return EAGAIN while the pool is suspended | FE33 | Oxide; not filed |
| 18 | e428301bda | a1284805c | spa_export_common: final txg can be one behind txg_sync_stop() | FE35 | Oxide; not filed |
| 37 | 2d57a6488d | b9d181609 | zpool export waits for the pool to sync while holding spa_namespace_lock | FE33 | Oxide; not filed |

### ZIL and durability (20-22, 45)

| # | commit | Change-Id | subject | tracker | upstream status |
|---|---|---|---|---|---|
| 20 | 729e8e1ac5 | 3cd167fa5 | ZIL ignores cache flush errors, so fsync can return 0 for data that isn't stable | PT12 | Oxide, along the lines proposed in OpenZFS #16314; not filed |
| 21 | 5d4b70befa | 04eb63a03 | ZIL: allow zil_commit() to fail with error | PT8 | OpenZFS 967b15b888; illumos 18754 filed, CR 5303 |
| 22 | a6eb9162f5 | 2ede462f5 | txg_sync should handle write errors in ZIL | IL47 | OpenZFS 7316fdd1c0; not filed |
| 45 | 1bf296f6a1 | 374c2436d | a failed dmu_sync() write's space can be reused in its txg, while the log points to it | FE6 | Oxide; not filed |

### Other kernel fixes (19, 23-25, 35, 36, 38-40, 44, 46, 49)

| # | commit | Change-Id | subject | tracker | upstream status |
|---|---|---|---|---|---|
| 19 | 06bd246080 | 5d95d75d2 | last close of a zvol stalls all zvol opens, closes and ioctls | FE36 | Oxide; not filed |
| 23 | 532848f62b | 91513e133 | a write that keeps failing while its disk answers probes is reexecuted forever | FE4 | Oxide; not filed |
| 24 | fd9934b5dc | b38c4ceb6 | trim and initialize threads can start on a vdev that was just detached | FE2, IL53 | Oxide; not filed |
| 25 | 58f3d52552 | 856358084 | Initialize metaslab range trees in metaslab_init | IL7 | OpenZFS 793c958f6f; illumos 18753 filed together with 35, CR 5302 |
| 35 | 009a8de6c9 | e50e950cf | Don't allocate from new metaslabs | IL7 | OpenZFS 5551dcd762; illumos 18753 filed together with 25, CR 5302 |
| 36 | d1173d1b7b | 0dedaff9e | Fix incorrect assertion in dnode_dirty_l1range | PT18 | OpenZFS e61b53475e; not filed |
| 38 | 6d5c070135 | 921bb2a17 | metaslab_activate() can find space in a metaslab with weight 0 | FE37 | Oxide; not filed |
| 39 | 6a8414409e | 2308c8816 | retried I/O shouldn't go in the persistent error log | PT13 | Oxide; not filed |
| 40 | 3ea358b6a5 | 0c8e28ad1 | a dataset hold that can't read the dataset's ZAP should fail, not assert | FE14 | Oxide; not filed |
| 44 | 7c26216083 | 413d50dce | Avoid panic in case of pool errors and missing L2ARC | IL15 | OpenZFS 2a49ebbb4d; not filed |
| 46 | 0ee2c21388 | e69baedb3 | zio_inject: a device or label fault with no guid applies to every leaf | — | Oxide; not filed |
| 49 | 44bbab39d8 | c0a1b5d9b | a mapped file's unwritable dirty pages keep its file system busy | FE15 | Oxide; not filed |

### Scrub, resilver and device removal (29, 30, 32, 41, 42, 47)

| # | commit | Change-Id | subject | tracker | upstream status |
|---|---|---|---|---|---|
| 29 | 21073a3d1a | 5f2bc90af | scrub can visit blocks born in the syncing txg | IL17 | Oxide; not filed; a prepared fix for OL17 would replace 29 and 30 |
| 30 | f64cf95d5a | d666dfc21 | resilver can visit blocks born in the syncing txg | IL17 | Oxide; not filed; a prepared fix for OL17 would replace 29 and 30 |
| 32 | 48aa9ea40e | 86d35d155 | Cancel initialize and TRIM before vdev_metaslab_fini() | IL13 | OpenZFS 635a01aafd; not filed |
| 41 | f1bba8850d | 719ff30bf | ZTS: test removing a mirror while a child is resilvering | IL14 | OpenZFS 47d5d5fc26; not filed |
| 42 | e6fe4a8584 | 6c872d38a | vdev_removal: don't remove a mirror with a child still resilvering | IL14 | OpenZFS de9a1a8d74; not filed |
| 47 | cb9129c1db | 37577ba03 | vdev_dtl_should_excise() shouldn't assert that a resilver covered the attach txg | IL6 | Oxide; illumos 18731 filed, CR 5275; OpenZFS #19906 |

### ztest fixes (26-28, 31, 33, 34, 43, 48)

| # | commit | Change-Id | subject | tracker | upstream status |
|---|---|---|---|---|---|
| 26 | 580c4bd27e | 7ffec0275 | ztest: scrub ddt repair | PT16 | OpenZFS 52b684236d, which also fixes `ddt_bp_create()`; not filed |
| 27 | 2ff7d63f48 | e35b0a132 | ztest: split block reconstruction | IL29 | OpenZFS 64bdf63f5c + 13d454c6ca, which also change `zdb` and a `vdev_indirect.c` limit; illumos 18666 filed, CR 5221 |
| 28 | 95299e53c5 | 5b2a2944c | ztest: scrub verification | PT16 | OpenZFS ce5fb2a7c6; not filed |
| 31 | 7e4dec577c | d98c1195b | ztest: don't fail reads on a pool without redundancy | OL10 | Oxide; not filed |
| 33 | afd4e14ed4 | caa4b724c | ztest: don't resilver from a device made unreadable by fault injection | IL4 | Oxide; illumos 18672 filed, CR 5231; OpenZFS #19792 |
| 34 | e1c24a3967 | 67021c871 | ztest: don't reguid while a log device can't be written | FE3 | Oxide; not filed |
| 43 | cc3cbf7f1f | 53a6e5b1c | ztest: don't remove a mirror with a child made unwriteable by fault injection | IL14 | Oxide; not filed |
| 48 | a73dd2f508 | 6018644f1 | ztest: try more combinations to reconstruct a damaged split block | FE40 | Oxide; not filed |

### zinject and other ports (50-55)

| # | commit | Change-Id | subject | tracker | upstream status |
|---|---|---|---|---|---|
| 50 | ca141eeaa9 | bf7475470 | Add corruption failure option to zinject(8) | — | OpenZFS d977122da9; not filed |
| 51 | 80d338e66c | 4c869297d | zinject: "no-op" error injection | — | OpenZFS 4725e543be; not filed |
| 52 | 099e18010c | 19c375be9 | zio: do no-op injections just before handing off to vdevs | — | OpenZFS b8c73ab780; not filed |
| 53 | df8526cca2 | 80c86ff49 | zinject: "io-prefail" error injection | — | the zinject part of OpenZFS 6562851406; not filed |
| 54 | 0328d91cdd | d1f7c194c | Ensure dsl scan prefetch queue is emptied | FE20 | OpenZFS d6496040d9; not filed |
| 55 | 37951532b6 | 3b47130d7 | Aggregate dataset space accounting deltas over a txg | FE21 | OpenZFS 2eae71cd17; illumos 18733 filed, CR 5277 |

### Commands that survive read errors (56-58)

| # | commit | Change-Id | subject | tracker | upstream status |
|---|---|---|---|---|---|
| 56 | 422ecb0f8b | 8b5dbec54 | zfs panic in zfs_fill_zplprops_impl() | FE32 | OpenZFS b129c6590e; not filed |
| 57 | dd6b31768f | e29633630 | ZTS: zfs create fails if it can't read its parent's properties | FE32 | Oxide test for 56; not filed |
| 58 | 7b81a7c1cc | 57639f7ee | zfs list panics when a volume's dnodes can't be read | FE23 | Oxide; not filed; OpenZFS issue #16228 is open with no fix |

### zfs-diagnosis (59, 60)

| # | commit | Change-Id | subject | tracker | upstream status |
|---|---|---|---|---|---|
| 59 | 0888818925 | e987435ec | zfs-diagnosis leaks pool handles | FE27 | Oxide; illumos 18743 filed, CR 5288 |
| 60 | ea210c9599 | 17746beda | zfs-diagnosis can fault a device of a pool for errors from before its import | FE29 | Oxide; not filed |

### The feature (61-74)

| # | commit | Change-Id | subject | tracker | upstream status |
|---|---|---|---|---|---|
| 61 | ce8d7f4296 | 43369aa5c | ☠️ failmode=death: a pool that can't write should fail, not suspend | FE22, FE4 | feature; includes FE22 (async destroy on a failing pool) and the `failmode=death` end of the FE4 reexecution cap |
| 62 | 4e8631c913 | b79447a85 | zpool export -F should not hang on a suspended pool | — | feature |
| 63 | 5015d55e4a | 455a5eff8 | a failed pool should drain without reading from its disks | FE5, FE18 | feature; FE18 is a pre-existing assertion |
| 64 | 8189bf2e89 | 46202c8b3 | a DDT lookup that can't read the DDT should not assert | FE1 | feature; an upstream version would have to do without `spa_failed()` |
| 65 | 9b63abe4f5 | 2a97bd5c2 | a deadlist insert that can't read the deadlist should fail a death pool, not panic | FE38 | feature; FE38 is a pre-existing bug |
| 66 | c4ba21de3c | 6cd4dab83 | zil_close() and the pool's background threads hang or panic on a failed pool | — | feature |
| 67 | f2f27d99e0 | 592902425 | ztest should fail its pool and export it | — | feature (ztest) |
| 68 | 7e24ee97ee | f87f152bd | zpool doesn't show or handle a failed pool | — | feature |
| 69 | 7c5219ab35 | 70dbecc0f | fsync() can succeed on a failed pool, and its open files, volumes and file systems keep it from being exported | FE26, FE39, AU4 | feature; FE39 and the illumos part of AU4 are pre-existing bugs |
| 70 | 8449cc2ceb | 0bfe18c3e | reboot hangs with a suspended pool | — | feature |
| 71 | 58c7c717e8 | 60b31e60d | zpool export -F should fail the pool, not try a normal export first | — | feature |
| 72 | 81d4f3aa0e | 37b784524 | export of a failed pool should free a send, receive or diff blocked on its pipe | — | feature; adds `thread_abort_sleep()` to genunix |
| 73 | 305c75b1ca | e9fedbd82 | FMA should diagnose a failed pool | — | feature |
| 74 | 396d2067b7 | de4e2199b | zfs receive panics if it can't read a file system's properties | FE25 | feature; the VERIFY is pre-existing, also in OpenZFS; overlaps illumos 18725 (CR 5272) |

### ZTS (75-78)

| # | commit | Change-Id | subject | tracker | upstream status |
|---|---|---|---|---|---|
| 75 | 9c104189d2 | c2ffd6dbd | ZTS: tests for failmode=death and forced export | FE41 | feature tests |
| 76 | 4482b10c36 | cba1d72ee | ZTS: hardforce export and failmode sync tests, adapted to failmode=death | — | feature tests, adapted from the unmerged OpenZFS #11082 and from OpenZFS 1f8c39ddb2 and b098c60ee6 |
| 77 | f53e4d0038 | dccc96ff3 | ZTS: share the helpers that check a pool's state | — | feature tests |
| 78 | 8499b41e6e | eb6453676 | ZTS: a failmode=death pool survives errors that ZFS recovers from | — | feature tests |

### Fixes that need the feature (79-91)

| # | commit | Change-Id | subject | tracker | upstream status |
|---|---|---|---|---|---|
| 79 | 0a7acdc509 | ef38510a9 | a destroy panics if its pool fails while it runs | FE31 | Oxide; not filed |
| 80 | 3ec0b36c2d | 5ee62f7da | unmapping a file during a forced unmount can panic | FE16 | Oxide; not filed; illumos-gate has the same race |
| 81 | c58a8511a9 | 7223e88e5 | writes in open context can panic when their pool fails | — | Oxide; not filed |
| 82 | eba59f20e1 | eb38eca60 | removing a log device can panic if the pool fails during the removal | — | Oxide; not filed |
| 83 | fb6a7396b8 | 6ed2d4223 | a block written just as its pool fails can read back as zeros | — | Oxide; not filed |
| 84 | 63bbb6c767 | 27ae6849e | a pool that fails while it is imported can panic, or be imported failed | — | Oxide; not filed |
| 85 | 9ebfd4fe3f | 66f35b357 | zpool export -F can hang behind a volume's first open | — | Oxide; not filed |
| 86 | 21a7dd3ff0 | 1579da3ea | a log write that never finishes can hang a failed pool's unmount, rollback or export | — | Oxide; not filed |
| 87 | 25a740f418 | 8dc63e9d2 | a vnode operation asleep outside a failed pool can hang its export | — | Oxide; not filed |
| 88 | 95c6d5e2ad | e295ceb5e | zpool.8 and spa_misc.c's lock order are wrong about failed pools | — | Oxide; not filed |
| 89 | 3fab0137ed | 4f0a9bbe7 | a split or device removal that fails on a failed pool can panic | FE47 | Oxide; not filed |
| 90 | d86b1b2aec | a1fbacb10 | zpool export -F refuses a pool because of another pool's failed swap volume | — | Oxide; not filed |
| 91 | a487a3e47f | e6186c04e | a fault of a failed pool's disk can hold up every pool command | — | Oxide; not filed |

## Who reviews what

George reviews the feature (61-91) and DESIGN.md. Matt is sending the prerequisites (1-60) upstream. 31 of them are OpenZFS ports, already reviewed there, so what needs checking is the adaptation to illumos (53 takes only the zinject part of its commit). Of the 29 Oxide prerequisites, 33, 47 and 59 are in review on code.illumos.org, and the rest have had no upstream review (apart from 9's two tests taken from OpenZFS 2303775fea).

Two sets of prerequisites depend on what happens upstream. Commits 10 and 37 keep an export from waiting under `spa_namespace_lock` for a suspended or slow pool (10 returns `EAGAIN` for a suspended one, and 17 lets ztest accept that). Upstream, only the unmerged OpenZFS #11082 does the same, and commit 61 rewrites their code into `spa_export_sync()`, so they are easiest to read alongside it. Commit 7 fixes a busy loop that 5 introduces; the illumos port being prepared carries OpenZFS's fix for the same loop, 2a963979a0, in its place.

The feature relies most directly on 3 and 5 (`TXG_WAIT_SUSPEND`, which lets a txg wait leave a suspended pool, and `DMU_TX_SUSPEND`, which marks the assignments that can't fail: they wait out a suspension, and get a txg on a failed pool), 13 and 14 (`spa_is_exporting` and `spa_export_thread`), 21 (`zil_commit()` returns an error) and 23 (`zio_reexecute_max`, the reexecution cap at which a `failmode=death` pool fails). Three feature commits also fix pre-existing bugs that could be split out for upstream: in 63 the `zfs_get_data()` assertion (FE18), in 65 the partial deadlist tree (FE38), and in 69 the mount teardown when the root znode can't be read after `zfsvfs_setup()` (FE39) and the `VERIFY0(dmu_objset_from_ds())` in `zfs_resume_fs()` (AU4).

## Testing

DESIGN.md's Testing section describes the tests and what they cover, and `chaos/README.md` the chaos campaign. All results are from DEBUG builds on illumos VMs. The full ZTS run, `forced-exit.run` and zloop ran on the tip's code, apart from two lines the tip rewraps for cstyle; the chaos campaigns ran on a build through commit 80, without the fixes in 81-91.

- Full ZTS (`common.run` without `l2arc`): 1,408 pass, 7 fail, 7 skipped. Five failures also fail on illumos master (`enospc_002_pos`, `projectspace_004_pos`, `refreserv_multi_raidz`, `send_encrypted_freeobjects`, `slog_014_pos`), `slog_lwb_write_error` fails on what `slog_014_pos` leaves behind, and `scrub_after_replace` fails because of 29 (see Open issues).
- `tools/forced-exit.run`: 171 pass and 1 is skipped (`mmp_reset_interval`, unsupported on illumos).
- Two flaky tests are fixed (in 75 and 83): `forced_export_pinned_zil`'s `lwb_in_flight` case, whose zinject often ran too late to fail the pool while its log block was in flight, and `failmode_death_enospc_reexecute`, which missed its case in about 63% of tries and gave up after 5.
- zloop: an 8-hour pair on the tip's code, with and without ztest's forced exit (`ztest -x`), completed 327 and 328 runs with no crashes; an earlier 12-hour pair, through commit 80, completed 482 on each side.
- Chaos: 2,342 iterations with no failures. In three, a suspended failmode=wait or continue pool wedged `zpool` commands (upstream behavior, FE19) until `zpool export -F` released it.
- Builds: every commit builds on its own, DEBUG kernel and packages, with no errors.

## Open issues

DESIGN.md's "Known limitations and open issues" lists the open problems in the design and code, including a panic from `mkdir` in `.zfs/snapshot` of a detached file system, whose fix is filed upstream but not on the branch (AU7), narrow panic windows in an async destroy on a failing pool (FE42), what the export does with I/O that a driver never completes, bugs found by reading the code (among them the export of a failed pool waiting for `zfsdev_state_lock` behind a volume's first open on another, suspended pool), and what is yet to be agreed upstream or changed in omicron. Open issues with the branch itself:

- 74 overlaps illumos 18725 (CR 5272, not yet integrated), which changes the same `zfs_resume_fs()` VERIFY; whichever integrates second has to be rebased onto the other (FE25).
- Subjects carry placeholder bug IDs, and 61's carries the ☠️ marker.
- Commits 61, 62 and 68 describe `zpool export -F` as arming the pool, which is what it does at each of them; 71 changes it to fail the pool at once.
- No non-DEBUG build of the tip has been tested.
- The branch is on stlouis d9acef1b04. stlouis has since integrated stlouis#1122 (0714ca89f4), which conflicts with it in `zvol.c` and `common.run`.
- At the tip, cstyle finds nothing in the C files that the branch changes that it doesn't also find in the base (`sys/ddt.h` mixes spaces and tabs). Earlier commits aren't all clean: a comment that 62 adds is 81 columns wide until 69 rewraps it.
- `replacement/scrub_after_replace` (illumos 18683, in the base) fails with 29: its scrub, set up in the replace's txg, no longer stands in for the resilver (see DESIGN.md, Results). OL17, which would replace 29 upstream, does the same, so the test has to be reworked or retimed there before OL17 integrates; it isn't changed here.

## Files here

- `DESIGN.md`: the design at the tip, with its tests and its open issues.
- `chaos/`: the chaos campaign, which fails a pool at a random moment under a sled-like workload and checks the fence, the export, and that every acknowledged write survives the import. `chaos/README.md` explains how to run it.
- `tools/zlr.sh`: runs zloop in a pool's directory for `ZLT` seconds (12 hours by default), restarting it when it exits early. Extra arguments go to ztest, so `-x` turns off ztest's forced exit.
- `tools/forced-exit.run`: a ZTS runfile for `zfstest -c`, with the tests the branch adds or changes and the existing groups that exercise the code it changes.
