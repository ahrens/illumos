# Forced export and failmode=death

This document describes how a ZFS pool fails rather than suspends: the `failmode=death` property, `zpool export -F`, and how a failed pool drains, is exported, is reported and is tested, with the decisions behind the design and its known limitations. It describes the code at the tip of the `agents/forced-exit` branch, and is committed in `forced-exit/` next to `README.md`, the review guide, which maps the branch's commits.

## Summary

The goal is that when a U.2 drive dies, its single-disk pool goes away without a reboot and without wedging the rest of the sled. This branch adds `failmode=death`: where a pool on `failmode=wait` or `continue` would suspend after an I/O error it can't recover from, a `failmode=death` pool fails. A failed pool never resumes and writes nothing more to its devices, every thread waiting on it returns, and its sync thread drains the dirty data without writing it. `zpool export` then removes the pool, whose disks stay at the last committed txg plus the intent log blocks already written.

`zpool export -F` fails a pool whatever its state and then exports it, losing what the pool hadn't synced except synchronous writes, which the intent log replays at the next import. It reaches the pool through a new ioctl that doesn't take `spa_namespace_lock`, which a thread asleep on a suspended pool may hold indefinitely. A reboot arms every pool, so that a pool that is or becomes suspended during shutdown fails rather than hanging the unmounts.

The export of a failed pool detaches its mounted file systems, fails its open volumes and cancels sends, receives and diffs blocked on their file descriptors, all in the kernel, then waits up to 20 s (by default) for any remaining holders and returns `EBUSY` if they stay. `zpool export` unmounts the detached file systems afterwards.

sled-agent has three things to do. It creates U.2 pools with `failmode=death`, or sets it on existing ones. It notices a failed pool: its health is FAILED, a new value its health parsing must accept, and FMA diagnoses `fault.fs.zfs.pool_failed` (ZFS-8000-LR). And it removes the pool with plain `zpool export`, run again after `EBUSY`, without halting zones or unmounting anything first. `zpool export -F` is for discarding unsynced changes on purpose: a pool on another failmode, or one sled-agent removes although it hasn't failed, such as a pool whose disk returns read errors but takes writes.

## Problem and goals

On stock stlouis, when a U.2 drive dies, its single-disk pool suspends. (Omicron sets `failmode=continue` on these pools when it imports them. On stock stlouis that fails with `EIO` only the changes assigned without `TXG_WAIT`; `write(2)` and volume writes still block while the pool is suspended.) The device doesn't come back, so the pool never resumes, and every thread that waits for it to make progress waits forever: txg waits, `zil_commit()` (and with it `fsync()`, synchronous writes and unmounts), sync tasks such as `zpool reguid`, and the last close of a volume with dirty data. Some of these waits hold a global lock: `zpool export`, `spa_vdev_exit()` and `spa_config_update()` wait under `spa_namespace_lock`, and a volume's last close under `zfsdev_state_lock`. Every `zpool` and `zfs` command, and every volume open and close on the sled, then blocks behind them. Nothing removes the pool: `zpool clear` can't resume it, `zpool export` waits for it, and a reboot hangs unmounting its file systems.

Prerequisite commits fix the waits that don't depend on the feature (a normal export of a suspended pool returns `EAGAIN` rather than waiting under `spa_namespace_lock`, and a volume's last close waits for its dirty data before it takes `zfsdev_state_lock`) and port the OpenZFS foundation the feature builds on (see Waits).

### Goals

In priority order:

1. No sled-wide wedge. A dead drive's pool never blocks administration of other pools or I/O to their volumes; for a `failmode=death` pool, with no operator action.
2. A failed pool goes away. `zpool export` removes it, dropping its unsynced data, detaching its file systems and failing its open volumes. If something outside ZFS keeps the pool busy, the export returns `EBUSY` and can be run again.
3. No false durability. On a failed pool, `fsync()`, `O_DSYNC` and `sync=always` writes, volume cache flushes and txg waits return `EIO`, never 0 for data that was dropped, except with `sync=disabled`, which promises no durability on any pool.
4. The pool stays importable: its disks are left at the last committed txg plus intact ZIL blocks.
5. A suspended pool never hangs an export: without `-F`, the export fails at once with `EAGAIN`.
6. Reviewable: native illumos code rather than a port of openzfs/zfs#11082, built on a small set of ported upstream prerequisites, not on larger upstream features that stlouis lacks.

### Non-goals

- I/O that never returns. Failing a pool doesn't cancel I/O that a driver already has. If such I/O keeps one of the pool's datasets referenced, the export returns `EBUSY` at its deadline; otherwise the export waits for it, uninterruptibly and without a deadline, until the driver completes it or, for I/O that `spa_sync()` waits for, the deadman, which this branch doesn't change, panics the system (see I/O that never completes). Likewise, a send or receive stopped by job control, or asleep uninterruptibly outside the pool, keeps the export returning `EBUSY`, as does a vnode operation on one of the pool's file systems asleep outside the pool.
- Resuming or destroying a failed pool. It can only be exported, and imported again; it can't write the labels that would mark it destroyed.
- Other platforms: how the code maps onto OpenZFS's Linux and FreeBSD layers.

## Overview

The code calls the mechanism forced exit (`spa_exit.c`, `spa_exit_*()`, `ZFS_IOC_POOL_FORCE_EXIT`) and the state it ends in failed (`SPA_EXIT_FAILED`, `spa_failed()`, `ZPOOL_CONFIG_FAILED`, health FAILED).

### Pool states

A pool is in one of four states. Suspended is the stock `spa_suspended` state; armed and failed are values of `spa_exit`. A pool is never failed and suspended at once, since failing a pool ends its suspension, and never stays armed and suspended, since arming a suspended pool fails it.

| State | How a pool gets there | What it does |
|---|---|---|
| Healthy | Import, or `zpool clear` of a suspended pool | Behaves as usual. |
| Suspended | An unrecoverable I/O error on a pool on `failmode=wait` or `continue` that isn't armed (`zio_suspend()`) | Parks the I/O that failed and waits for `zpool clear` (`zio_resume()`). |
| Armed | `spa_exit_arm()`: at reboot, and in ztest | Behaves as usual until it would suspend, then fails instead. |
| Failed | `spa_fail()`: where a `failmode=death` or armed pool would suspend, when a suspended pool is armed, or by `zpool export -F` | Fenced off from its devices, drains, and waits to be exported. |

A failed pool leaves only by being exported, and its next import starts out healthy. Pool state and failure has every transition.

### What failing a pool does

1. `spa_fail()` marks the pool failed, once. It ends any suspension, posts one `ereport.fs.zfs.io_failure` carrying `pool_failed`, wakes the waiters, and reexecutes any I/O parked during a suspension into the fence.
2. No zio reaches a leaf vdev (`zio_vdev_io_fence()`). Reads and `ZIO_FLAG_CANFAIL` writes (ZIL blocks, `dmu_sync()`, labels, uberblocks) get `EIO`; other writes, flushes and TRIMs succeed without doing anything, allocations get fake DVAs, and frees are no-ops (see I/O on a failed pool).
3. The sync thread keeps draining txgs without writing them. No uberblock is written, so `spa_last_synced_txg()` stays at the last committed txg (see Syncing context).
7. Every wait ends, with `EIO` where it waited for a txg that wasn't committed (see Waits), and the pool waits to be exported (see Export and unload).

### Invariants

The rest of the design implements five invariants:

- One-way. `spa_exit` only moves forward until the pool is exported, and `zio_resume()` refuses a failed pool. A failed pool's in-core state doesn't match its disks (blocks written nowhere, fake DVAs, deadlists and space maps left as they were), so only a fresh import can bring it back.
- No writes after failure. Once `spa_failed()` is true, ZFS starts no new I/O to the pool's leaf vdevs, even if the drive comes back: every zio stops at the fence in `zio_vdev_io_start()`, queued zios included. Syncing context therefore only has to avoid panicking and hanging; its in-core state is discarded at export. Two kinds of write can still land. I/O that a driver accepted before the failure completes when the driver completes it, so a txg whose uberblocks reached the disks just before the failure, ahead of its odd labels, is on disk although its waiters got `EIO`. And raw and dump volume I/O, which reaches the disks without a zio, checks `spa_failed()` just before it is issued, unsynchronized with `spa_fail()`, so a request racing the failure can still issue the one chunk it checked: at most one volblocksize extent, inside the volume's preallocated blocks and never in pool metadata (see Raw volumes).
- No waiter sleeps forever. `txg_wait_open()`, txg waits with `TXG_WAIT_SUSPEND` or `TXG_WAIT_FAILED`, `dmu_tx_wait()`'s dirty-data wait and the sync thread's idle wait check `spa_failed()`; the other txg waits end because the failed pool keeps draining txgs. This releases threads that wait holding `spa_namespace_lock`, `zfsdev_state_lock`, `z_teardown_lock` or the SCL locks. Waits for I/O that a driver never completes are the exception, including txg waits for a txg that a log write held up that way keeps open.
- Drain, don't abandon. Instead of tearing down DMU state by hand, the sync thread runs with every I/O fenced. Dirty data goes through the normal sync paths, success paths included, which release the holds that dirty records have on dbufs, dnodes and datasets; what they can't complete (metaslab and space map updates, deferred frees, vdev configuration changes) is discarded. A block that syncing context can't read is zero-filled and marked poisoned (`dbuf_poison()`).
- No false success. On a failed pool `zil_commit()` returns `EIO` (0 with `sync=disabled`), and so do txg waits, sync tasks and vdev changes whose txg wasn't committed. Since fenced writes succeed without I/O, the answer comes from the pool's state, never from a zio's result; the writes whose success callers rely on (ZIL blocks, labels, uberblocks, `dmu_sync()`) are `CANFAIL`, and the fence fails them.

## Pool state and failure

### The `spa_exit` state

`spa_exit` (`spa_exit_state_t`, in `struct spa`) is `SPA_EXIT_NONE`, `SPA_EXIT_ARMED` or `SPA_EXIT_FAILED`, and moves only forward: from `NONE` to `ARMED` or `FAILED`, and from `ARMED` to `FAILED`. It is protected by `spa_suspend_lock`, which already orders suspension and resumption, so arming, failing, suspending and resuming are each decided atomically with respect to the others. `spa_failed()` reads it without the lock, as `spa_suspended()` reads `spa_suspended`. `spa_activate()` resets it, along with `spa_exit_offset` (the next fake DVA offset) and `spa_exit_unloading`, so a new import, a `spa_reset()` or a retried load starts out healthy. `spa_get_stats()` adds `ZPOOL_CONFIG_FAILED`, which isn't stored on disk, to a failed pool's config (see Userland).

### `failmode=death`

`ZIO_FAILURE_MODE_DEATH` (3, in `sys/zio.h`) follows `wait`, `continue` and `panic` and is stored in the pool's property object like them; the property table, `spa_prop_validate()`'s range check, the ereports' `pool_failmode` ("death") and `zpool(8)` include it. A kernel without this change treats the value as `wait`, since it tests only for `panic` and `continue`.

`zpool set failmode=death` takes effect when its txg syncs. It can't be set on a suspended pool: `ZFS_IOC_POOL_SET_PROPS` refuses one with `EAGAIN` (`POOL_CHECK_SUSPENDED`), so `spa_prop_validate()`'s in-core special case for suspended pools is reached only by a pool that suspends after that check (see Questions from code reading). A suspended pool is removed with `zpool export -F` instead.

### `spa_fail()`

`spa_fail()` (`spa_exit.c`) fails a pool once. Under `spa_suspend_lock`, it returns if the pool has already failed; otherwise it sets `SPA_EXIT_FAILED` and takes the parked I/O tree, if any, with `zio_unsuspend()`, which also clears `spa_suspended` and broadcasts `spa_suspend_cv`. Doing both in one critical section keeps the failure from racing with `zio_resume()`. With the lock dropped, it logs a console warning, posts `FM_EREPORT_ZFS_IO_FAILURE` (which carries `pool_failed`, since the state is already set), wakes the txg waiters (`txg_exit_wakeup()`) and the writers waiting for dirty space (`dsl_pool_exit_wakeup()`), and reexecutes the parked tree into the fence (`zio_exit_reexecute()`).

`spa_fail()` waits for nothing on the pool, so it can be called from the zio pipeline and from syncing context as well as from ioctls. Its callers are `zio_suspend()`, `spa_exit_fail_by_name()`, `spa_export_common()` (for a hardforce export), `dsl_deadlist_insert_failed()`, `dsl_scan_iterate_failed()` and ztest.

### Where a pool fails

`zio_suspend()` decides between suspending and failing, under `spa_suspend_lock`. A pool fails if it is on `failmode=death`, has already failed, or is armed and not on `failmode=panic`; otherwise it suspends, or panics, as on stock illumos. A pool that fails doesn't park the zio that wanted to suspend it: `zio_suspend()` reexecutes it into the fence (`zio_reexecute_dispatch()`). Every path that would suspend a pool goes through `zio_suspend()`:

- `zio_done()`, when the root of a tree has `ZIO_REEXECUTE_SUSPEND` set. `zio_done_report()` sets it for a failed logical zio that is an allocating write that isn't `CANFAIL` and got `ENOSPC` or has been reexecuted `zio_reexecute_max` times (see Retry cap); a read or free that got `ENXIO`, outside scrub, resilver and pool load, on a pool not on `failmode=continue`; or any other zio that isn't `CANFAIL` and isn't being reexecuted.
- `spa_sync_rewrite_vdev_config()`, when the labels and uberblocks can't be written. On a failed pool it returns `B_FALSE`: the txg wasn't committed.
- `mmp_thread()`, when no multihost write has succeeded for `zfs_multihost_fail_intervals` intervals. It writes nothing to a failed pool.

`ENOSPC` in syncing context gets no exception: a suspended pool can't free space, since frees, deferred frees, `zpool add` and device expansion all need a txg to sync, and `zpool clear` only retries the allocation. Open context keeps writers out of the slop space, so a syncing-context `ENOSPC` means an accounting error or an allocation race.

Two places where any pool panics make a `failmode=death` pool fail instead, keeping its disks at the last synced txg: `dsl_deadlist_insert_failed()`, when a deadlist can't take a block that its dataset has already charged to it, and `dsl_scan_iterate_failed()`, when an async destroy can't read the free or obsolete bpobj, or its bptree traversal fails with an error other than `EIO` or `ECKSUM`, which it ignores (see Read errors in syncing context).

### Arming

`spa_exit_arm()` moves a pool from `SPA_EXIT_NONE` to `SPA_EXIT_ARMED` under `spa_suspend_lock`, then fails it if it is suspended (`spa_fail_impl()` with `suspended_only`). Because `zio_suspend()` decides under the same lock, a pool armed just as it suspends is failed by one of the two. An armed `failmode=panic` pool still panics. An armed pool that never suspends behaves as usual, export included. One that suspends during its export fails instead; `spa_export_sync()`'s `TXG_WAIT_SUSPEND` wait ends, and the export goes on as the export of a failed pool.

Pools are armed by ztest (see Testing) and at reboot by `spa_shutdown_callb()`, a `CB_CL_UADMIN_PRE_VFS` callback that `uadmin(2)` runs just before `vfs_unmountall()`. Unmounting a file system of a suspended pool waits in `zil_commit()` for a resumption that never comes, which would hang the reboot. The callback walks `spa_namespace_avl` under `spa_namespace_avl_lock`, holds each loaded, writable pool with `spa_exit_hold()`, and arms it with the leaf lock dropped. It arms rather than fails so that healthy pools still sync at shutdown.

Arming, unlike the `failmode` property, can't be undone; it lasts until the pool is exported. `zpool export -F` fails the pool rather than arming it, so that the outcome doesn't depend on whether the pool would have synced, which the caller can't know.

### Failure is one-way

`zio_resume()` returns `EBUSY` on a failed pool, and `zfs_ioc_clear()` returns `EIO` for one before it clears any error counts or reopens any device. So do the ioctls that change a failed pool's devices, reopen them or scan the pool (commit 91, `pool_open_devices()`): `zfs_ioc_vdev_set_state()` (`zpool online`, `offline`, and FMA's faults and degrades), `zfs_ioc_vdev_attach()` (including zfs-retire's hot spare attaches), `zfs_ioc_vdev_detach()`, `zfs_ioc_vdev_add()`, `zfs_ioc_vdev_remove()`, `zfs_ioc_vdev_split()`, `zfs_ioc_vdev_setpath()`, `zfs_ioc_vdev_setfru()`, `zfs_ioc_pool_reopen()`, `zfs_ioc_pool_scan()`, since a scrub or resilver reopens the devices (`dsl_scan()`), and `zfs_ioc_pool_initialize()`, `zfs_ioc_pool_trim()`, `zfs_ioc_pool_upgrade()` and `zfs_ioc_pool_reguid()`. Each would wait for whatever I/O the pool still has in flight: as a writer of `SCL_STATE` and `SCL_ZIO` (`spa_upgrade()` takes every lock), or of every lock while holding `spa_namespace_lock` (`spa_vdev_enter()`), or for a txg while holding `spa_namespace_lock`, which a log write in flight holds open (initialize, trim, reguid). A `zpool status` that holds `spa_namespace_lock` queues behind the writer, and every pool command behind the lock, so that all of them wait for a device that may be going away; and reopening the devices would post a `probe_failure` for each leaf, which FMA would diagnose as a fault of every disk. For the same reasons, the async thread of a failed pool drops its config update, remove, autoexpand, probe and resilver-done tasks. `spa_export_common()` refuses to destroy a failed pool (`EIO`), since it can't write the labels that would mark it destroyed. Export is the only way out. Userland describes what `zpool clear` and `zpool destroy` report.

### A pool that fails while it loads

A pool can fail while an import, an open from the cache file or a split loads it. A read during the load that can't fail fails a `failmode=death` or armed pool rather than suspending it, and once the load has started the sync thread, so can a write to its first txgs, or `zpool export -F` (see `spa_exit_fail_by_name()`). Nothing the load does after that would reach the disks.

`spa_load_impl()` checks `spa_failed()` after it waits for its first txgs to sync (`spa_claim_max_txg`, if it claimed log blocks; otherwise it doesn't wait, and the first txgs usually sync, or fail, after `spa_import()` can no longer back out), and again just before it restarts initialize and TRIM, whose leaf-ZAP lookups assert that they succeed. On a failed pool it skips the rest of the load, but doesn't return an error: its caller would unload the pool, and the next open would load it again, healthy (`spa_activate()` resets `spa_exit`). An open from the cache file then leaves the pool loaded and failed until it is exported, like a pool that fails later; an import or a split backs out (below). A load that does return an error on a failed pool isn't retried or rewound: `spa_load_best()` returns the error, since `spa_load_retry()` would undo the failure, and in recovery mode would rewind the pool. `spa_load()` posts no ereport for such a load, beyond the `io_failure` that `spa_fail()` posts, so that zfs-diagnosis doesn't also diagnose a pool that can't be opened.

`spa_import()` refuses a pool that has failed by the time the load and the checks of its spares and cache devices are done: it unloads and removes the pool and returns `EIO`, leaving no pool behind. That is the last point at which it can back out, since once the async tasks resume, unloading the pool would wait for them with `spa_namespace_lock` held, which the config update task takes. A pool that fails once they have resumed stays imported and failed, and `spa_import()` returns `EIO`; it is exported like any failed pool. A split whose new pool has failed by the end of its load returns `EIO` and leaves the disks in the original pool.

Restarting initialize and TRIM, at the end of a load or after a split or device removal that fails, reads each leaf vdev's ZAP, which a failed pool can read only if it is cached. `vdev_initialize_restart()` and `vdev_trim_restart()` do nothing on a failed pool, since nothing that a restarted thread writes would reach its disks, and accept a failed lookup if the pool fails while they walk the vdev tree, as it can after `spa_load_impl()`'s last check.

## Failing a pool from userland

### `ZFS_IOC_POOL_FORCE_EXIT`

`ZFS_IOC_POOL_FORCE_EXIT` (0x5a53) is a legacy pool ioctl handled by `zfs_ioc_pool_force_exit()`. `zc_name` names the pool; a nonzero `zc_cookie` fails every pool whose name starts with `zc_name`, for `zpool export -aF`, which may know a pool only by a truncated kstat name. The ioctl uses `zfs_secpolicy_config`, as `ZFS_IOC_POOL_EXPORT` does, with `POOL_CHECK_NONE` and no history logging, since either would need the pool: a pool check opens it with `spa_open()`, which takes `spa_namespace_lock`, and so does logging history (`zfs_log_history()`).

Each pool goes through `zfs_pool_fail()`, which returns `EBUSY` and leaves the pool alone if it has an open volume that failing the pool couldn't let go of or that the system can't do without (`zvol_pinned_minors()`): one that COMSTAR holds (`ZVOL_EXTERNAL`), a dump device (`ZVOL_DUMPIFIED`) or a swap device. Failing such a pool would leave it failed, unwritable and still imported. Otherwise it calls `spa_exit_fail_by_name()`. `zvol_pinned_minors()` runs before the pool is failed, while it may still be suspended, so it mustn't wait for the pool. It walks `zvol_list`, which holds every volume from `zvol_create_minor()` to `zvol_remove_zv()`, under `zvol_list_lock`, which no thread holds while it waits for a pool. It takes neither `zfsdev_state_lock` nor `zv_state_lock`, which a volume's first open holds while it opens and reads the pool, so a volume can be opened, closed or pinned while it looks, as it can between the check and the failure (see Questions from code reading). A hardforce export calls `zfs_pool_fail()` too, so the kernel doesn't depend on the caller having used this ioctl. Userland describes the order in which `zpool export -F` and `-aF` call it, open the pool and export it.

### Finding a pool without `spa_namespace_lock`

`spa_namespace_lock` can be held indefinitely by a thread asleep on the pool that `-F` is meant to fail: `zpool reguid` waiting for its sync task, `spa_vdev_exit()` waiting for its txg, or `spa_import()` waiting in `spa_config_update()`. So `spa_namespace_avl` is also guarded by a new leaf lock, `spa_namespace_avl_lock`, which `spa_add()` and `spa_remove()` take inside `spa_namespace_lock` around their tree updates. Since every change holds both locks, `spa_lookup()` still reads the tree under `spa_namespace_lock` alone, while `spa_exit_fail_by_name()`, `spa_failed_by_name()` (used by `zfs_fail_mounts()`, `zvol_fail_minors()` and `zcp_eval()`), `spa_exit_names()` and `spa_shutdown_callb()` read it under the leaf lock alone and don't wait for an import or export in progress. `spa_exit_find()` looks a pool up by pool or dataset name with a static search key guarded by the leaf lock, since a `spa_t` is too big for the stack. Nothing blocks while holding the leaf lock, except for `spa_exit_names()`'s `KM_SLEEP` allocations. The lock order is `spa_namespace_lock`, then `spa_namespace_avl_lock` (see Lock order).

The alternatives were walking the tree with no lock, which can misread it while an import or export rebalances it, and polling `spa_namespace_lock` with `mutex_tryenter()`, which never succeeds if its holder never wakes.

### `spa_exit_fail_by_name()`

`spa_exit_fail_by_name()` finds the pool under the leaf lock, returning `ENOENT` if there is none and `EBUSY` for the root pool. It holds the pool with `spa_exit_hold()`, drops the leaf lock, calls `spa_fail()` if the hold succeeded and the pool's sync thread is running (`spa_sync_on`), releases the hold, and returns 0. `spa_fail()` runs without the leaf lock because it posts an ereport, takes the txg and dirty-data locks and dispatches I/O.

The hold is a count, `spa_exit_holds`, under the leaf lock. Before `spa_unload()` closes the DSL pool, `spa_exit_unload_wait()` sets `spa_exit_unloading` and waits for the count to reach zero. A held pool therefore stays loaded and, since `spa_remove()` frees a pool only after unloading it, its `spa_t` stays valid. A `spa_refcount` reference would instead count as a user keeping the export busy. `spa_exit_hold()` refuses, and nothing is failed, for a pool that isn't loaded, one that another export or reset is unloading, and a read-only pool, which has nothing to lose; such a pool is exported as usual.

`spa_exit_fail_by_name()` doesn't fail a pool whose import hasn't started its sync thread (`spa_sync_on`), nor arm it instead, which would outlast the `zpool` command. The export then waits for the import in `spa_lookup()`, uninterruptibly, and `spa_export_common()` fails the pool once the import is done. An import drops `spa_namespace_lock` while it loads (`spa_load_thread`), so if a `wait` or `continue` pool's first sync suspends, the import waits for its claim txg without the lock: commands on other pools keep working, while every lookup of this pool, that export's included, waits with it. A `zpool export -F` issued once `spa_sync_on` is set (a second one, if the first came earlier) fails the pool and releases both, as does a reboot; a `failmode=death` pool fails instead of suspending. The import then fails with `EIO` and leaves no pool (see A pool that fails while it loads). A suspension later in `spa_import()`, while it sets properties or updates the config (`spa_config_update()`), happens with `spa_namespace_lock` held, and blocks every pool lookup until `-F` fails the pool, after which the import returns `EIO`.

The root pool can't be failed by name or by a hardforce export: the system needs it, and it can't be exported. (`spa_shutdown_callb()` still arms it at reboot, like any other pool.) The kernel refuses it with `EBUSY` in `spa_exit_fail_by_name()` and, for a hardforce export, in `spa_export_common()`. `zpool` finds it in `mnttab` (`root_pool_name()`), refuses `-F` on it, and leaves it out of `zpool export -a`.

### Lock order

`spa_namespace_avl_lock` is a leaf. `spa_add()` and `spa_remove()` take it under `spa_namespace_lock`, and so does `spa_unload()`'s `spa_exit_unload_wait()` when `spa_unload()` runs under that lock (a failed import or load, `spa_evict_all()`); the export's `spa_unload()` runs without it. It is also the mutex of `spa_exit_hold_cv`, on which `spa_exit_unload_wait()` waits for the holds to go away. `spa_exit_fail_by_name()` and `spa_shutdown_callb()` drop it before they call `spa_fail()` or `spa_exit_arm()`.

`zfsdev_state_lock` comes before `spa_namespace_lock`: a volume's first open, `zvol_create_minor()` and `zvol_set_volsize()` open the pool while holding it. Since `spa_exit_unload_wait()` can wait for the holds with `spa_namespace_lock` held, and, through a volume's first open whose load fails, with `zfsdev_state_lock` held as well, a thread holding a pool with `spa_exit_hold()` takes neither lock. `spa_fail()` takes `spa_suspend_lock` (with zio locks under it) and then `tx_sync_lock` and `dp_lock`. `zvol_pinned_minors()` takes `zvol_list_lock`, which comes after `zfsdev_state_lock`, and `swapinfo_lock` under it; nothing that holds `zvol_list_lock` waits for a pool, and it is released before `zfs_pool_fail()` calls `spa_exit_fail_by_name()`. Elsewhere, `spa_activate()` takes `spa_suspend_lock` under `spa_namespace_lock`, syncing context calls `zio_suspend()` and `spa_fail()` holding `SCL_CONFIG` as reader, and `spa_streams_lock` comes after `spa_namespace_lock` (see The stream registry).

## I/O on a failed pool

Once a pool has failed (`spa_failed()`), no zio reaches a leaf vdev. The disks stay at the last committed txg plus the log blocks written before the failure, even if the device comes back, so blocks freed in uncommitted txgs and reallocated in memory are never overwritten.

The fence is a void fence: most fenced writes succeed without I/O rather than failing. Syncing context assumes its writes succeed (`dbuf_write_done()` asserts that `io_error` is 0, and `dsl_pool_sync()` wraps its root zios in `VERIFY0(zio_wait())`), so a void fence lets the sync thread drain dirty data through its normal success paths, and only reads need error handling. The cost is that a successful zio on a failed pool doesn't mean its data is on disk, so durability is decided from pool state, never from a zio's result: `zil_commit()` returns `EIO` once the pool has failed (unless sync=disabled), and `txg_wait_synced_flags()` returns `EIO` for any txg after `spa_last_synced_txg()`, which stops advancing at the failure (see Waits).

### The fence

`zio_vdev_io_start()` hands every zio for a leaf vdev of a failed pool to `zio_vdev_io_fence()`, ahead of the vdev cache, the vdev queue, fault injection and the device; interior vdevs run as usual and see each child's fenced result. `spa_failed()` is an unlocked read, so a zio that passes the check just as the pool fails is issued normally and handled as I/O in flight (below).

| I/O on a failed pool | Result |
|---|---|
| Read, including L2ARC reads and reads the vdev cache could have served | `EIO` |
| Write whose logical zio is not `ZIO_FLAG_CANFAIL` | Success; nothing is written |
| Write whose logical zio is `CANFAIL`: log blocks, `dmu_sync()` writes, labels, uberblocks | `EIO`; the callers handle it and never report the data as stable |
| Flush (`DKIOCFLUSHWRITECACHE`), `CANFAIL` or not | Success |
| TRIM | Success |
| Allocation | A fake DVA (`zio_dva_allocate_fake()`); the metaslab code isn't called |
| Free | No-op |
| Claim | No-op (`metaslab_claim()` returns 0) |

The fence judges `CANFAIL` by the logical zio (`io_logical`), because vdev children are always `CANFAIL` (`ZIO_VDEV_CHILD_FLAGS`). Labels and uberblocks normally aren't written on a failed pool at all (`spa_sync_rewrite_vdev_config()` returns first); the fence is the backstop.

A zio that the vdev queue hasn't seen completes through `zio_vdev_io_bypass()`. One with `ZIO_FLAG_DONT_QUEUE` (queued before the failure, or an aggregate) is on the queue's active tree and must still pass through `zio_vdev_io_done()` for `vdev_queue_io_done()` to remove it, so the fence sets `ZIO_FLAG_IO_BYPASS` and hands it to `zio_interrupt()`; `zio_vdev_io_done()` then runs from the interrupt taskq, lets the queue remove it, and returns early on the flag. Completing it inline would recurse once per queued zio, because `vdev_queue_io_done()` issues the next queued zio with `zio_execute()`, which comes straight back to the fence.

An aggregate is never `CANFAIL` itself (it inherits only `ZIO_FLAG_AGG_INHERIT`). For an aggregate write, the fence sets `EIO` on each parent whose logical zio is `CANFAIL`, so that a log block aggregated with ordinary writes isn't taken as written, and lets the aggregate succeed. An aggregate read fails all of its parents.

Raw and dump zvol I/O (`zvol_rawio()`, `zvol_dumpio()`) doesn't use zios, and checks `spa_failed()` itself (see Raw volumes).

### Allocation

On a failed pool `zio_dva_allocate()` calls `zio_dva_allocate_fake()` instead of the metaslab code. The fake DVA is on a real top-level vdev, the rotor vdev of the zio's metaslab class (or of the normal class), so that `vdev_lookup_top()`, `bp_get_dsize()` and dataset space accounting work unchanged.

Each copy gets its own offset: `DVA_FAKE_OFFSET_BASE` (2^63 bytes) plus a per-pool counter, `spa_exit_offset`, advanced atomically by the asize rounded up to `1 << spa_max_ashift`, since one counter serves every vdev. Offsets must be unique because the ARC identifies a block by DVA and birth txg, and a block written after the failure exists only in the ARC. Real offsets are below 8 EiB (see the blkptr layout in `sys/spa.h`), so fake DVAs can't collide with real ones, including cached blocks written before the failure; `DVA_IS_FAKE()` tests for one. `zfs_blkptr_verify()` skips its per-DVA bounds checks on a failed pool, and on a healthy pool reports a fake DVA with `zfs_panic_recover()`.

A fake allocation can't fail, so nothing allocated after the failure becomes a gang block. Dedup would read the DDT, so on a failed pool `zio_ddt_write()` turns a dedup write into a plain write; doing this at the DDT stage also covers a dedup write set up before the failure.

An asynchronous write still reserves its throttle slots in `zio_dva_throttle()`. `zio_dva_allocate_fake()` gives them back at once, clears `ZIO_FLAG_IO_ALLOCATING` so that the vdev children don't release them again, and calls `zio_allocate_dispatch()`, so each queued write releases the next as soon as it is allocated and none is stranded behind the throttle.

Log blocks are the exception: `zio_alloc_zil()` calls `metaslab_alloc()` directly, with no `spa_failed()` check, so a commit already in progress when the pool fails (a new `zil_commit()` returns `EIO` before it writes anything), and `zil_failed_wait()` when it issues a log's open lwb, still allocate from the in-core metaslab state, which can mean loading a metaslab (see Questions from code reading). The writes fail in the fence, and the allocations are dropped with the rest of the unsynced metaslab state at unload.

### Frees and claims

A failed pool frees nothing. `zio_free()` and `metaslab_free()` return at once, the latter covering `zio_dva_free()` and `zio_dva_unallocate()`. `zio_free_sync()` returns a null zio, and accepts the hole block pointers that a poisoned bpobj can hand it. `zio_dva_free_failed()` (see ZIL) does nothing. A claim zio runs, but `metaslab_claim()` returns 0. The space maps are never written again, and fake DVAs must never reach a range tree. What the metaslabs tracked for unsynced txgs is discarded at unload (see Export and unload).

### Cache misses

`arc_read()` of a block the ARC holds completes as usual, whether its DVA is fake or real; a miss fails in the fence. That makes the void fence safe to read through: a block written after the failure has its only copy in the ARC, and a miss on one that kept a real DVA (see I/O in flight) would otherwise return whatever the disk holds at that offset. The dbuf layer is stricter: open context gets `EIO` for a dbuf that isn't cached (other than a hole), even if the ARC holds the block, and syncing context gets zeros when the ARC misses (see Syncing context).

### I/O in flight

The fence doesn't cancel I/O already in the driver. It completes, usually with an error, through the usual stages to `zio_done()`, which reads `spa_failed()` once, into `failed`, so that what it reports and what it absorbs agree. On a failed pool `zio_done()` skips `zio_done_report()` (see Reports), folds in its logical children's errors, and then absorbs the error of any zio that isn't a read, a null zio or `CANFAIL` by clearing `io_error`, so that the write or free succeeds (flushes and claims are always `CANFAIL`, so they keep their errors).

The absorb follows the logical children's errors so that it sees the final error, and precedes the unallocation step (`zio_dva_unallocate()` or `zio_dva_free_failed()`, run only for an allocating zio that still has an error or wants to be reexecuted). An absorbed write therefore keeps the DVA that its parent block already points to, and its done callback (`dbuf_write_done()`, `arc_write_done()`) sees a success. Since vdev, gang and DDT children are `CANFAIL`, the absorb happens at the logical zio. Reads, and the null zios that wait for them, keep their errors. `zio_done()`'s final assertion, that only a `CANFAIL` zio completes with an error, allows any error on a failed pool.

One case is reexecuted instead: a logical allocating write that failed before it was allocated (`BP_GET_NDVAS(bp) == 0`), such as one that got `ENOSPC` just before the pool failed. Its ready callback has already seen the empty block pointer, which looks like a hole, so absorbing the error would lose the data. It is marked `ZIO_REEXECUTE_NOW` and counted in `io_reexecute_count`, and the next attempt gets a fake DVA and completes in the fence. Such a write gets one more reexecution than `zio_reexecute_max` allows, so that one that used up its retries before the pool failed still gets its fake DVA. A fake allocation can't fail, so one is enough; the bound only keeps a write that keeps failing before its allocation from being reexecuted forever, and past it the error is absorbed and the block left a hole.

### Parked I/O

A pool that fails where it would suspend parks nothing: `zio_suspend()` calls `spa_fail()` and reexecutes the zio into the fence (see Where a pool fails). Since an already-failed pool takes the same path, this also catches a tree that completes after the failure still wanting `ZIO_REEXECUTE_SUSPEND` from a child that finished before it.

Only a pool that suspended before it failed has parked I/O: a failmode=wait or continue pool that `zpool export -F` fails, or a suspended pool that is armed. `spa_fail()` takes the parked tree with `zio_unsuspend()` in the `spa_suspend_lock` critical section that sets `SPA_EXIT_FAILED`, so it can't race with `zio_resume()`. `zio_exit_reexecute()` dispatches a task on the claim issue taskq that calls `zio_reexecute()` on the Godfather root, which has never been executed, and then `zio_wait()` on it. Reexecution zeroes the block pointers of allocating writes, so they get fake DVAs; every write then succeeds in the fence and every read fails, with no device I/O, so the tree can't fail the same way again.

### Reports

On a failed pool `zio_done()` skips `zio_done_report()` entirely: no vdev statistics (`vdev_stat_update()`, `vs_slow_ios`), no `delay`, `io` or `data` ereports, no persistent error log entries, and no reexecution or suspension decision. Pending checksum reports are freed unposted. The `io_failure` ereport that `spa_fail()` posts is then FMA's one event for the failure (see FMA).

### Retry cap

An allocating write that isn't `CANFAIL` and fails with anything but `ENOSPC` is reexecuted at once (`ZIO_REEXECUTE_NOW`) so that it can be allocated elsewhere. If the only disk it can go to fails every write but answers probes, nothing faults the disk, and the write would be reexecuted forever without the pool suspending, hanging the txg syncs behind it. `zio_done_report()` therefore counts reexecutions in `io_reexecute_count` and, after `zio_reexecute_max` (default 100), marks the write `ZIO_REEXECUTE_SUSPEND` instead; `ENOSPC` suspends at once. `zio_reexecute()` doesn't reset the count, so after `zpool clear` a write that still fails suspends the pool again at once. On a failmode=death pool the suspension becomes `spa_fail()`. Once a pool has failed, a write that failed before it was allocated gets one reexecution past the cap, into the fence (see I/O in flight).

Only a failing write's first and last attempts post `io` and `data` ereports (see FMA). Neither a zio that will be reexecuted, which hasn't failed for good, nor a failed `CANFAIL` write, which nothing points to, is added to the persistent error log.

### Deadman

The deadman is unchanged. `spa_deadman()` turns itself off only while the pool is suspended, and a failed pool isn't. Fenced zios never wait on a device, and a queued one is on the active tree only until the interrupt taskq runs it, so they can't trip `vdev_deadman()`. An I/O that the driver never completes is outside this design. If it belongs to `spa_sync()`, the sync thread and every txg wait without `TXG_WAIT_SUSPEND` wait for it, and the deadman, on by default (`zfs_deadman_enabled`), panics the system once `spa_sync()` has run for `zfs_deadman_synctime_ms` (1000 s), as on any pool. A hung open-context read never trips the deadman, since `spa_sync()` keeps completing. What such I/O does to the export is under I/O that never completes.

## Waits

A thread that waits on a pool that never makes progress keeps what it holds (`spa_namespace_lock`, `zfsdev_state_lock`, `z_teardown_lock`, a dataset) forever. On a failed pool every wait ends, except one for I/O that the driver never completes, directly or through a txg that such a log write holds open (see Deadman, and I/O that never completes), with `EIO` where the caller asked about durability. A few waits check `spa_failed()`; the rest wait for a txg and end because the sync thread keeps draining txgs, quickly, since fenced I/O completes at once. Each waiter returns along its normal path and releases its holds.

### Suspend foundation

Failure builds on OpenZFS's waits that break out when a pool suspends, ported as prerequisites.

`txg_wait_synced_flags(dp, txg, flags)` generalizes `txg_wait_synced_sig()`. With `TXG_WAIT_NONE` it waits for the txg to sync; `TXG_WAIT_SIGNAL` returns `EINTR` on a signal; `TXG_WAIT_SUSPEND` returns `ESHUTDOWN` if the pool is or becomes suspended, which `zio_suspend()` announces with `txg_wait_kick()`; `TXG_WAIT_FAILED` (local) returns `EIO` if the pool has failed or fails, but keeps waiting while it is suspended. `txg_wait_synced()` is the `TXG_WAIT_NONE` form and returns nothing.

`dmu_tx_assign()` takes a `dmu_tx_flag_t`, renamed from the `TXG_*` flags (`DMU_TX_NOWAIT`, `DMU_TX_WAIT`, `DMU_TX_NOTHROTTLE`), plus the new `DMU_TX_SUSPEND`, which requires `DMU_TX_WAIT`. On a suspended pool `dmu_tx_try_assign()` returns `ESHUTDOWN`, which `dmu_tx_assign()` turns into `ERESTART` (wait and retry) for a `DMU_TX_SUSPEND` caller, `EIO` on a failmode=continue pool even with `DMU_TX_WAIT` (stock illumos blocks there), and `ERESTART` otherwise.

`tx_break_on_suspend` tells `dmu_tx_wait()` whether to pass `TXG_WAIT_SUSPEND`: it is set for callers without `DMU_TX_SUSPEND`, so that a wait begun before the pool suspended returns and the assignment is reassessed, and cleared when the suspension itself produced the `ERESTART`, so that the next wait blocks until the pool resumes. A local change clears it for `DMU_TX_NOWAIT` callers too, without which ZPL operations that assign with `DMU_TX_NOWAIT` (create, mkdir, remove, rename) spin on a suspended pool; OpenZFS fixed the same loop in 2a963979a0. The dirty-data wait in `dmu_tx_wait()` also breaks on suspension when `tx_break_on_suspend` is set (a local change), and `zio_suspend()` wakes it with `dsl_pool_exit_wakeup()`.

`DMU_TX_SUSPEND` marks the callers that can't handle an assignment error: they pass `DMU_TX_WAIT | DMU_TX_SUSPEND` and `VERIFY0()` the result. On a failed pool the flag means "assign a txg anyway" (below).

### What failure wakes

`spa_fail()` sets `SPA_EXIT_FAILED` and calls `zio_unsuspend()` under `spa_suspend_lock`, then, if the pool has a DSL pool, `txg_exit_wakeup()` (under `tx_sync_lock`) and `dsl_pool_exit_wakeup()` (under `dp_lock`):

| Condition variable | Broadcast by | Waiters |
|---|---|---|
| `spa_suspend_cv` | `zio_unsuspend()` | `zio_resume_wait()` |
| `tx_sync_done_cv` | `txg_exit_wakeup()` | `txg_wait_synced_flags()` |
| `tx_sync_more_cv` | `txg_exit_wakeup()` | `txg_sync_thread()` |
| `tx_quiesce_done_cv` | `txg_exit_wakeup()` | `txg_wait_open()`, and `txg_sync_thread()` waiting for a quiesced txg |
| `tx_quiesce_more_cv` | `txg_exit_wakeup()` | `txg_quiesce_thread()`, `txg_delay()` |
| `dp_spaceavail_cv` | `dsl_pool_exit_wakeup()` | `dmu_tx_wait()`'s dirty-data wait |

Of these, the waits whose loops check `spa_failed()` are `txg_wait_open()`, `txg_wait_synced_flags()` with `TXG_WAIT_SUSPEND` or `TXG_WAIT_FAILED`, `dmu_tx_wait()`'s dirty-data wait, and `txg_sync_thread()`'s idle wait, which doesn't wait out `zfs_txg_timeout` while the failed pool has dirty data. `zio_resume_wait()` returns because a failed pool isn't suspended. The others go back to waiting for their txg and end when the drain reaches it, including waits that were blocked on a suspended pool, since its parked I/O is reexecuted into the fence (see Parked I/O).

### Each wait on a failed pool

| Wait | On a failed pool |
|---|---|
| `txg_wait_synced_flags()` with `TXG_WAIT_SUSPEND` or `TXG_WAIT_FAILED` | Returns at once: `EIO`, or 0 for a txg committed before the failure. |
| `txg_wait_synced_flags()` without it | Waits until the txg has drained (or until a signal, with `TXG_WAIT_SIGNAL`, which returns `EINTR`), then returns `EIO` if the txg is after `spa_last_synced_txg()`, else 0. |
| `txg_wait_synced()` | As `TXG_WAIT_NONE`; its `VERIFY` accepts the `EIO`, which the caller doesn't see. |
| `txg_wait_open()` | Returns at once. |
| `dmu_tx_assign()` | `EIO` without `DMU_TX_SUSPEND`, whatever the failmode and other flags; a txg with it. |
| `dmu_tx_wait()` | The dirty-data wait returns at once, and `dmu_tx_delay()` is skipped if dirty data is still at or above `zfs_dirty_data_max`. Txg waits as above. |
| `dsl_sync_task()` | `EIO` unless its open-context check fails or its txg was committed before the failure, even if the task ran; `dsl_sync_task_sync()` drops a failed pool's tasks without running them (see Syncing context). |
| `spa_vdev_exit()` | Waits for the drain; `EIO` for a change whose txg wasn't committed. |
| `spa_vdev_state_exit()` | Waits for the drain; `EIO` for any state change. |
| `zil_commit()` | `EIO`, or 0 with sync=disabled (see ZIL). |

A plain txg wait waits for the drain rather than returning at once because its caller may free state that the sync thread still refers to once the wait returns; a `TXG_WAIT_SUSPEND` or `TXG_WAIT_FAILED` caller asked to be told about trouble and handles an early return. The error comes from comparing the txg with `spa_last_synced_txg()`: `spa_sync()` advances `spa_ubsync` only for a txg it commits, so `spa_last_synced_txg()` stays at the last txg known to be on disk while `tx_synced_txg` advances through drained txgs.

`dmu_tx_try_assign()` refuses a failed pool before it checks for suspension or the write throttle, so a caller without `DMU_TX_SUSPEND` gets `EIO` even on a failmode=wait pool. A `DMU_TX_SUSPEND` caller gets a txg, and its changes drain unwritten. That is simpler than giving these callers error paths they don't have, and their changes would be dropped anyway. If the assignment has to wait, `dmu_tx_wait()` returns at once, and `dmu_tx_assign()` sleeps a tick (`delay(1)`) before retrying so that it doesn't spin while the pool drains.

### `VERIFY0(dmu_tx_assign())` sites

Thirteen callers assign with `DMU_TX_WAIT | DMU_TX_SUSPEND` and `VERIFY0()` the result. Each gets a txg on a failed pool and is safe there:

- `dsl_sync_task_common()`: the task is dropped, and `dsl_sync_task()` returns `EIO`.
- `vdev_initialize_change_state()`, `vdev_initialize_write()`, `vdev_trim_change_state()`, `vdev_trim_range()`: the ZAP update's sync task is dropped, and its free function frees the argument. The thread stops when it can't load a metaslab, without marking the vdev complete.
- `spa_condense_indirect_commit_entry()`, `spa_vdev_remove_thread()`: check `spa_failed()` after assigning and commit the unused tx; the first returns `EIO`, the second stops the removal (`svr_thread_exit`).
- `dsl_scan_restart_resilver()`, `zil_create()`, `zil_destroy()`: proceed, and their changes only drain.
- `zil_lwb_write_issue()`, `zil_commit_itx_assign()`: reached by a commit already in progress (a new `zil_commit()` returns `EIO` first), by `zil_suspend()`, which calls `zil_commit_impl()` without that check, and, for `zil_lwb_write_issue()`, by `zil_failed_wait()`, which issues the last open lwb; the log block's write fails in the fence.
- `spa_unload_log_sm_flush_all()`: not called, since `spa_should_flush_logs_on_unload()` is false on a failed pool.

Every other `dmu_tx_assign()` caller checks the error, and gets `EIO`.

## Syncing context

A failed pool keeps its sync thread, which drains the dirty data through the normal sync code rather than a separate teardown walk over DMU state: `dsl_pool_sync()` already releases the holds that dirty data has on dbufs, dnodes and datasets, and what the skipped phases leave behind is discarded per txg or at unload. Nothing it writes reaches the disks, so syncing context only has to avoid panicking and hanging; its in-core state is thrown away at export.

### Draining

`txg_sync_thread()` doesn't wait out `zfs_txg_timeout` on a failed pool while `dp_dirty_total` is nonzero, so the dirty data left, and what txs assigned before the failure and `DMU_TX_SUSPEND` callers add, drains as fast as the sync thread can go: writes complete in the fence without I/O, and reads fail at once. No uberblock is written, so `spa_last_synced_txg()` stays at the last committed txg while `tx_synced_txg` advances, and `txg_dispatch_callbacks()` calls the commit callbacks of a txg after `spa_last_synced_txg()` with `ECANCELED`, asking at dispatch because the pool can fail after `spa_sync()` has committed the txg. Txg waits and assignments on a failed pool are covered under Waits.

### What `spa_sync()` does on a failed pool

`spa_sync_iterate_to_convergence()` checks `spa_failed()` at the start of each pass, after `dsl_pool_sync()`, after the frees, after the group of `ddt_sync()`, `dsl_scan_sync()`, `svr_sync()` and `spa_sync_upgrades()`, after `spa_flush_metaslabs()`, for each vdev in the `vdev_sync()` loop, and before `spa_sync_deferred_frees()`. A pass that starts on a failed pool runs only `dsl_pool_sync()`; a pass in which the pool fails runs to the next check. Either way `spa_sync_discard()` drops the rest of the pass: it empties `spa_free_bplist[txg]`, takes each dirty vdev off `spa_vdev_txg_list` with `vdev_sync_discard()` in place of `vdev_sync()`, and zeroes the removal's `svr_bytes_done[txg]`. The loop still iterates until the MOS is clean. A vdev change whose txg drains this way hasn't synced: a log device's removal (`spa_vdev_remove_log()`) checks `spa_failed()` after it waits for the txg that would destroy the device's metadata and ZAPs, and on a failed pool returns `EIO` and leaves the device in the pool, as it still is on disk, passivated and marked as removing.

The pool can fail at any point in a pass, from a write in this txg or from `zpool export -F` in another thread, and without the checks the rest of the pass would sync frees and metaslabs, reading space maps. Within a group there are no checks: `dsl_scan_sync()` stops on its own (see Read errors in syncing context), and the others get poisoned blocks for whatever they read.

| Phase | On a failed pool |
|---|---|
| `spa_sync_condense_indirect()` | Not started if the pool had failed when `spa_sync()` began |
| `spa_sync_config_object()`, `spa_sync_aux_dev()`, `spa_errlog_sync()`, `spa_sync_frees()` (or deferring the frees), `ddt_sync()`, `dsl_scan_sync()`, `svr_sync()`, `spa_sync_upgrades()`, `spa_flush_metaslabs()`, `spa_sync_deferred_frees()`, `metaslab_class_evict_old()` | Skipped |
| `dsl_pool_sync()` | Runs, into the fence (below) |
| `vdev_sync()` | Replaced by `vdev_sync_discard()` |
| `spa_sync_rewrite_vdev_config()` | Returns `B_FALSE` (without writing, if the pool had already failed), so `spa_ubsync` isn't updated, even for a txg whose uberblocks reached the disks before its odd labels' writes failed |
| `vdev_sync_done()` | Runs for metaslabs that synced before the failure, which keeps the space accounting consistent |
| `spa_sync_close_syncing_log_sm()` | Runs, accepting an empty log space map |

Inside `dsl_pool_sync()`, the dirty datasets, dsl_dirs and the MOS sync as usual, their writes succeeding in the fence with fake DVAs (see I/O on a failed pool). What changes:

- `dsl_sync_task_sync()` drops each sync task with `EIO` without calling its check or sync function (see Waits): both may read, and the task's changes would be dropped anyway.
- `dmu_objset_do_userquota_updates()` doesn't update the user, group and project accounting ZAPs, which it would have to read; `dmu_objset_discard_synced_dnodes()` releases the synced dnodes instead.
- `dsl_dataset_block_kill()` still updates the dataset's space accounting, but frees do nothing (see Frees and claims) and `dsl_deadlist_insert()` returns without adding the block. Since deadlists and dataset accounting then disagree, `dsl_dataset_space_written()` and `dsl_dataset_space_wouldfree()` return `EIO` on a failed pool.

### Poisoned reads

Syncing context reads indirect blocks, dnode blocks, ZAPs and bpobjs while it drains, and much of that code reads with `DB_RF_MUST_SUCCEED`, ignores the result, or VERIFYs it. Rather than add error handling at each site, a block that syncing context can't read is poisoned. On a failed pool, `dbuf_read_impl()` issues every syncing-context read with `ZIO_FLAG_DONT_PROPAGATE`, whatever the caller's flags (`DB_RF_CANFAIL` included, since much of the ZAP code VERIFYs those too). The fence fails the read, and `dbuf_read_done()` calls `dbuf_poison()`, which gives the dbuf a zero-filled ARC buffer, sets `db_poisoned` and marks it `DB_CACHED`. `ZIO_FLAG_DONT_PROPAGATE` keeps the error from the caller's parent zio, so a caller that reads several blocks through one zio gets them all. Syncing context here is `dsl_pool_sync_context()`: the sync thread, the `dp_sync_taskq` threads, and pool creation and `dsl_pool_open()` at load (`spa_is_initializing`).

In syncing context zeros look like holes: there is nothing to free under a zeroed indirect block, a zeroed block of dnodes reads as free objects, and anything written over a poisoned block goes into the fence. The ZAP code checks `dmu_buf_is_poisoned()`: a poisoned header block opens as an empty microzap (`mzap_open()`), a poisoned leaf as an empty leaf (`zap_open_leaf()`), and a poisoned pointer-table block fails with `EIO` (`zap_table_load()`), since there is no leaf for it to point to.

`dbuf_read()` finishes every read on a failed pool that fails or finds a poisoned block through `dbuf_read_poison()`, which also poisons a block left uncached by a read issued just before the pool failed, if the caller is in syncing context or passed `DB_RF_MUST_SUCCEED`. A poisoned block reads successfully in syncing context and fails with `EIO` in open context. Bonus buffers are never poisoned; their dnode block is. Reads that don't go through dbufs (`arc_read()` from traversal, the scan or the ZIL) get `EIO` from the fence and take their own error paths.

Open context never gets zeros as data, since it could take them for real data or real holes. On a failed pool `dbuf_read_impl()` returns `EIO` in open context, without issuing I/O, for any uncached block that isn't a hole, and for a hole whose parent is poisoned, which is a hole only because the parent was zeroed. A real hole, such as the first block of an object created in a tx assigned before the failure, still reads as zeros. A caller that must have the buffer, such as `dmu_buf_will_dirty()`, gets the poisoned buffer as well as the error, and its change goes nowhere. A write whose tx was assigned before the pool failed can find the blocks it writes, or the indirect blocks above them, uncached or poisoned: `dmu_write()`, `dmu_write_by_dnode()`, `dmu_write_embedded()`, `dmu_zero()` (a raw volume's initialization) and `dmu_copy_from_buf()` (a raw receive's `WRITE_BYREF` records) return without writing when their hold fails on a failed pool, since the write would never reach disk, and the unlinked-set updates accept the error the same way (see Inactive and unlinked files). Because setting up a dataset or dsl_dir reads ZAPs, deadlists and properties, `dsl_dataset_hold_obj()` and `dsl_dir_hold_obj()` return `EIO` in open context on a failed pool rather than instantiate a new one.

The `zfs:0:forced_exit` kstat counts the blocks poisoned on all failed pools since the module was loaded (`poisoned_reads`), and each poisoned block fires the `spa-exit-poisoned-read` SDT probe with the `spa_t` and the block's bookmark. The count isn't expected to stay at zero; it shows that the poisoning path ran. Nothing is logged per block.

### Read errors in syncing context

Syncing-context code that can't handle a read error meets one in two situations. On a failed pool, reads return poisoned zeros or `EIO`, and such code tolerates that only on a failed pool, usually as `VERIFY(err == 0 || spa_failed(spa))` followed by skipping the change. Before the pool has failed, a failmode=death pool can get real read errors, since the probe can fault the leaves of a dying disk before a failed write fails the pool. Where dropping a change would leak space or corrupt metadata, such a site fails a failmode=death pool and panics any other, as upstream (see Where a pool fails).

Deadlists. Loading a deadlist's tree keeps no partial tree if the ZAP or an entry's bpobj can't be read, so the next user tries again; `bpobj_open()`'s `ENOENT` for a bpobj whose dnode reads as zeros becomes `EIO`, so that it isn't taken for the end of the ZAP. On a failed pool, callers that can't load the tree leave the deadlist alone, and clones treat it as empty, as space queries (`dsl_deadlist_space_range()`) do on any pool. On a pool that hasn't failed, an insert that can't load the tree or read or extend its bpobjs, or that finds no entry for the block, goes to `dsl_deadlist_insert_failed()`.

DDT. On any pool, `ddt_lookup()` marks an entry whose read fails with anything but `ENOENT` as `dde_failed`, with zeroed phys, and returns `NULL` for it until it is synced; `ddt_sync()` leaves the on-disk DDT alone for it. `zio_ddt_write()` then writes a plain block, and `zio_ddt_free()` skips the refcount decrement, leaking the block rather than guessing its references; treating the unread entry as empty could replace the real one at the next sync.

Dataset holds. On any pool, `dsl_dataset_hold_obj()` returns read errors from the remap deadlist lookup, `load_zfeature()` and the bookmark-names lookup (`DS_FIELD_BOOKMARK_NAMES`) instead of asserting, and takes only `ENOENT` for `DS_FIELD_IVSET_GUID` as absent, so a read error doesn't set errata 8308.

Destroy sync tasks. A destroy already running when the pool fails continues on poisoned reads or `EIO`. On a failed pool, a head destroy skips `zil_destroy_sync()` if it can't read the objset, a snapshot destroy stops if it can't hold the previous or next snapshot and skips the steps that need a snapshot or head it can't hold, and both tolerate missing ZAP entries; `dmu_object_free()` returns 0 for an object that reads as free, and `bpobj_free()` skips what it can't open or read.

Async destroy and the scan. On a failed pool `dsl_process_async_destroys()` returns `EIO` at entry and after each iteration (free bpobj, bptree, obsolete bpobj), and its block callbacks return `EIO`, since the iterator would hand them all-zero block pointers from poisoned bpobj blocks; `dsl_scan_sync()` returns on the error. On a pool that hasn't failed, an iteration error other than `ERESTART` (or, from the bptree, `EIO` and `ECKSUM`, which are tolerated as upstream) goes to `dsl_scan_iterate_failed()`. `dsl_scan_active()` returns `B_FALSE` on a failed pool, so the sync thread doesn't keep syncing on behalf of a scan.

Background threads. The removal thread, the condense and checkpoint-discard zthrs, and the initialize and TRIM threads stop on a failed pool's read errors rather than asserting, and the errors from their sync tasks are VERIFYed only on a pool that hasn't failed.

Any other syncing-context function running when the pool fails continues on poisoned blocks, and an unaudited VERIFY in it can fire. The sites above are those that code reading, ztest and chaos testing found; four async-destroy sites can still panic (see Known limitations and open issues): the hole_birth `VERIFY` in `traverse_impl()`, `ASSERT0(bt_bytes)` in `bptree_iterate()`, the `DMU_POOL_OBSOLETE_BPOBJ` `EQUIV()` in `dsl_process_async_destroys()`, and `bpobj_open()` of object 0 in `bpobj_iterate_impl()`.

## Export and unload

### The export

`zfs_ioc_pool_export()` computes one deadline, `spa_exit_deadline()`: `TXG_SIZE * zfs_txg_timeout` seconds (20 s by default), as long as the pool could take to sync what it had in flight. It bounds the waits in `zfs_fail_mounts()` for log writes, vnode operations and mounts in progress, `zvol_fail()`'s waits, and the wait for holders (`spa_export_failed_wait()`); nothing else in the export has a deadline (see I/O that never completes, and Questions from code reading for the locks the export takes without one). A hardforce export first fails the pool by name (`zfs_pool_fail()`, see Failing a pool from userland) and returns `EBUSY` if that refuses. The ioctl then detaches the pool's mounted file systems (`zfs_fail_mounts()`) and fails its open volumes (`zvol_fail_minors()`), both no-ops unless the pool has failed, and calls `spa_export_by()`. If that returns `EBUSY` and a second round of both finds something to fail, it exports once more: a pool that failed during the export's own sync still had them. If the pool hadn't failed when the export began, the second round gets a deadline of its own, since the sync may have used up the first, and the dirty data of the volumes and file systems it fails needs time to drain.

`spa_export_common()`, which also destroys and resets pools, does the following for a pool that is loaded and syncing (`spa_sync_on`):

1. Under `spa_namespace_lock`, look the pool up (`spa_lookup()` waits out an import or export of it in progress). Return `ZFS_ERR_EXPORT_IN_PROGRESS` if another thread is exporting it, `EIO` for a destroy of a failed pool, and `EBUSY` for a hardforce export of the root pool. Set `spa_is_exporting`, take a reference, drop the lock and stop the async tasks.
2. For a hardforce export, fail the pool (`spa_fail()`).
3. If the pool hasn't failed, sync it without `spa_namespace_lock` (`spa_export_sync()`), then take the lock, drop the reference and sync again under the lock.
4. If the pool has failed, before or during step 3, return `EIO` for a destroy; otherwise wait for its holders (`spa_export_failed_wait()`).
5. Set `spa_export_thread`, wait for evicting objsets, and return `EBUSY` if references or fault injection handlers remain (handlers are allowed for a reset).
6. Drop the lock. Return `EXDEV` for an active shared spare unless the export is forced. Stop initialize, TRIM and autotrim. Unless the pool has failed, is being reset, or `spa_export_skip_update` (a test tunable that leaves the labels and cache file as after a power loss) is set, dirty every label with the new state, flush the log space maps if wanted, and set `spa_final_txg`.
7. `spa_unload()` and `spa_deactivate()`; then, under the lock, update the cache file, `spa_remove()` the pool (a reset keeps the `spa_t`), and wake the waiters in `spa_lookup()`.

An error clears `spa_is_exporting` and `spa_export_thread`, resumes the async tasks and wakes the waiters in `spa_lookup()`. A failed pool stays failed and imported, and the export can be run again.

### Syncing before the export

`spa_export_sync()` waits for the dirty data, which may be all that holds some objsets open, with `txg_wait_synced_flags(..., TXG_WAIT_SUSPEND | TXG_WAIT_SIGNAL)`. It returns `EAGAIN` if the pool is or becomes suspended, and `EINTR` on a signal. If the pool fails while it waits (a failmode=death pool whose export sync hits its dead disk, or an armed pool that suspends), it returns 0 and the export continues on the failed path. A plain export of a suspended pool on another failmode therefore returns `EAGAIN` instead of hanging under `spa_namespace_lock`, and the pool can still resume. `spa_history_log_nvl()` doesn't wait for a suspended pool either; it drops the export's history record.

The first sync runs without `spa_namespace_lock`, so that a slow pool doesn't block administration of every other pool. The second, under the lock, picks up what was dirtied meanwhile, and the lock is held from there to the reference check, apart from `spa_export_failed_wait()`'s sleeps on a failed pool, so that nothing opens the pool in between.

In the kernel, `force` (`-f`) only allows exporting a pool with an active shared spare; `zpool` uses `-f` to unmount forcibly.

### Failed and hard-forced exports

A failed pool is exported whatever the flags, plain `zpool export` included, even with busy file systems and open volumes. Three things make the export fail: an active shared spare, which needs `-f` (`EXDEV`, since `spa_export_common()`'s spare check has no failed-pool exemption); a volume that COMSTAR holds or that is the dump device (see Volumes the export can't fail); and anything else still holding the pool at the deadline, which returns `EBUSY`. I/O that a driver never completes can also block it (see I/O that never completes). A failed pool can't be destroyed, since it can't write the labels that mark a pool destroyed; a destroy returns `EIO` (steps 1 and 4), also when the pool fails during its own sync.

`hardforce` (`zpool export -F`) fails the pool whatever its state and never tries a normal export first (see Decisions). After `zpool` and `zfs_ioc_pool_export()` have failed it by name, `spa_export_common()` fails it once more after `spa_lookup()` has waited out any import in progress, which covers a pool whose import hadn't started syncing when the by-name call looked. A pool that isn't syncing, such as one imported read-only, isn't failed and is exported normally.

### Waiting for holders

Threads that `spa_fail()` woke still hold the pool while they fail out, so `spa_export_failed_wait()` waits for `spa_refcount_zero()`, and for fault injection handlers to be removed unless the pool is being reset. Holders don't signal when they let go, so it polls, sleeping in `cv_timedwait()` on `spa_namespace_cv` (which drops `spa_namespace_lock`) for `MAX(hz / 10, 1)` ticks, about 100 ms, or until the deadline. On each pass it cancels the pool's sends, receives and diffs (`spa_streams_cancel()`, see Send, receive and diff), which may be blocked on a pipe rather than on the pool. The wait isn't interruptible. At the deadline it logs how many references and injection handlers are left (`zfs_dbgmsg()`), without naming the holders, and returns `EBUSY`. The deadline is the one that `zfs_fail_mounts()` and `zvol_fail_minors()` wait against too, so a file system or volume that they couldn't let go of by then, because of log writes, vnode operations or I/O still in progress, makes this wait return `EBUSY` without waiting further.

The wait runs before `spa_export_thread` is set, because `spa_lookup()` waits while another thread is importing (`spa_load_thread`) or exporting (`spa_export_thread`) the pool, and every command that looks the pool up, `zpool list` among them, would otherwise wait as long as this does. `spa_is_exporting` keeps other exports of the pool out meanwhile.

### Labels, final txgs and the cache file

The export stops initialize, TRIM and autotrim, and flushes the log space maps of a pool that hasn't failed, before it sets `spa_final_txg`, so that they can't dirty a txg past it. `spa_final_txg` is `MAX(spa_last_synced_txg() + 1, tx_open_txg) + TXG_DEFER_SIZE`, computed with `SCL_ALL` held as writer. Taking `SCL_ALL` waits behind a `spa_sync()` in progress, after which the open txg can be two past the last synced txg, and `txg_sync_stop()` syncs through the open txg plus `TXG_DEFER_SIZE`; `vdev_config_sync()` asserts that no txg past `spa_final_txg` writes the labels.

A failed pool doesn't set the new state, dirty the labels or flush the log space maps (`spa_should_flush_logs_on_unload()` is false for it), and `spa_final_txg` stays `UINT64_MAX`. Its labels keep the state of the last committed txg, as after a power loss. It is removed from the cache file as usual.

### Unload

`spa_unload()` first waits for threads failing the pool by name to release their holds (`spa_exit_unload_wait()`, see Failing a pool from userland). `txg_sync_stop()` then syncs through the open txg plus `TXG_DEFER_SIZE` as usual; on a failed pool those txgs drain without I/O, so it ends quickly. Nothing in `spa_unload()` has a deadline, so I/O that a driver accepted and never completes still blocks it (see I/O that never completes).

Draining leaves little behind: each txg discards what its skipped phases would have consumed, and dropped nowait sync tasks free what their sync functions would have consumed through their free functions (such as `vdev_mapping_free()`), so `dsl_pool_close()` and `dmu_objset_evict()` need no changes. What remains is discarded at unload:

- Metaslabs. On a failed pool, `metaslab_fini()` vacates the defer, allocating, freeing, freed and checkpointing trees, and takes `ms_deferspace` out of the space accounting: allocations and frees that never synced were never accounted, but deferred frees were. If the pool failed after a metaslab synced in a txg, `metaslab_sync_done()` has already dropped that txg's later allocations and frees the same way.
- The DDT. `ddt_unload()` discards the in-core entries (`ddt_discard()`).
- The ARC. `dsl_pool_close()` flushes the pool's buffers as always, fake-DVA buffers included; one it misses can't alias a block of a later import, since fake offsets are above any real offset (see Allocation).

`spa_deactivate()` accepts errors from the `spa_txg_zio` roots on a failed pool, whose open-context I/O the fence may have failed.

### I/O that never completes

Failing a pool doesn't cancel I/O that a driver already has, and a zio holds no pool reference itself, so what a stuck I/O does to the export depends on what it keeps from finishing.

- If it keeps one of the pool's datasets referenced, and no earlier step of the export waits for it, the export returns `EBUSY` at its deadline, and the pool stays failed and imported; a rerun waits again. This covers a log write in flight, whichever dataset it belongs to (`zfsvfs_detach()` and `zvol_fail()` bound their `zil_failed_wait()` and their wait for the dirty data, except for a page that a file going inactive was writing out when the pool failed; see below), volume I/O in progress (`zvol_fail()`), a vnode operation that holds its file system's `z_teardown_lock` while it waits for the I/O (`zfsvfs_detach()` bounds its wait for the lock), a thread holding a dataset while it waits for the I/O, and a sync write in a txg that dirtied a user dataset, whose dirty hold keeps the dataset and its `dsl_dir`'s pool references.
- Otherwise the export waits for the I/O without a deadline and uninterruptibly, wherever it first needs it. Before the reference check that can be a `txg_wait_synced()` in the teardown or in a volume's last close (the latter under `zfsdev_state_lock`) while the sync thread is stuck, or a log write holds a txg open, for dirty data that their bounded waits didn't see (a page written out as its file goes inactive, say, or the data of a volume whose last open went away during `zvol_fail()`, which then closes it whatever its waits found), or `spa_async_suspend()` behind an async thread or zthr stuck on the I/O. After it, `spa_export_thread` is set, and the export can stop in `vdev_initialize_stop_all()`, `txg_sync_stop()`, the wait for the async zio roots or `spa_config_enter(SCL_ALL, RW_WRITER)` in `spa_unload()`; every `spa_lookup()` of the pool (`zpool status`, `zpool list`, `zfs` on its datasets, another export) then waits too, while other pools are unaffected.

Such an export ends only when the driver completes the I/O, or when the deadman panics the system for a stuck `spa_sync()` write (see Deadman).

### `spa_namespace_lock`

Several waits on a pool hold `spa_namespace_lock`: `spa_vdev_exit()` and `spa_config_update()` wait for their txg, and `spa_open_common()` takes `SCL_CONFIG` to generate a config. They aren't restructured: on a failed pool they end because its txgs keep draining, unless a log write in flight holds a txg open (see I/O that never completes), and `spa_vdev_exit()` returns `EIO` for a change whose txg wasn't committed (see Waits). The commands that would start such a wait on a failed pool refuse it (see Failure is one-way). On a suspended pool of another failmode they block until the pool resumes, as upstream, or until `zpool export -F` fails it without taking the lock (see Failing a pool from userland).

`spa_config_change_txg()` picks the txg that a configuration change made under `SCL_ALL` belongs to (`spa_vdev_config_enter()`, `spa_config_update()`). On a failed pool that is the txg after `spa_syncing_txg`, not after `spa_last_synced_txg()`, which has stopped while later txgs drain. `tx_synced_txg` can't be used, since `txg_sync_thread()` updates it only after `spa_sync()` drops `SCL_CONFIG`.

A suspended failmode=wait or continue pool can also wedge every pool command when an `SCL_ALL` writer such as `spa_vdev_resilver_done()` queues behind its stalled `spa_sync()`; this upstream behavior is left as is (see Known limitations and open issues).

## ZIL

A commit that returns 0 must be on disk and replayed at the next import. On a failed pool a successful zio doesn't mean that (see I/O on a failed pool), so the answer to a commit comes from `spa_failed()`, never from how a zio or a txg wait completed.

### Errors from `zil_commit()`

`zil_commit()` returns `int`, from a port of OpenZFS 967b15b888, where it always returns 0; the error cases are local. It returns `EIO` at once, without assigning a commit itx, if the pool has failed. If the pool fails while the commit waits, `zil_commit_impl()` checks `spa_failed()` after the wait and returns `EIO`, because the lwbs or txg it waited for may have completed without reaching a disk. A suspended log (`zl_suspend`) waits for the txg as before, but only until the pool fails (`TXG_WAIT_FAILED`), and returns `EIO` if it has failed. With `sync=disabled`, or on a pool that isn't writeable, it returns 0 without looking at the pool.

Lwb writes are `ZIO_FLAG_CANFAIL`, so on a failed pool the fence fails them, and their waiters take the usual fallback for a failed lwb, a wait for the txg, which returns at once on a failed pool (`TXG_WAIT_FAILED`): a log write of another dataset that reached a device before the failure can hold the txg open for good, and the waiter, in `fsync()`, holds its file system's `z_teardown_lock`, which an unmount or detach needs. The final `spa_failed()` check then returns `EIO`. It also covers an lwb written before the failure and flushed after it: the flush succeeds in the fence, but the data may be only in the drive's cache.

A commit blocked on a suspended pool (failmode `wait` or `continue`) is released when the pool fails: `zil_commit_itx_assign()` and `zil_lwb_write_issue()` assign with `DMU_TX_SUSPEND`, which gets a txg on a failed pool, and `spa_fail()` wakes the txg waiters. A commit waiting on an lwb whose write reached a device before the failure waits for that device.

The itx walks (`zil_get_commit_list()`, `zil_async_to_sync()`, `zil_remove_async()`) cover `TXG_CONCURRENT_STATES` txgs from `zil_first_unsynced_txg()`. On a failed pool `spa_last_synced_txg()` stops while later txgs drain and `zil_clean()` runs for them, so the walk starts after `tx_synced_txg` instead. Otherwise the window would fall behind the open txg, and a commit itx outside it would never be processed, leaving its waiter asleep.

The base already passes an lwb's write error, including that of a `dmu_sync()` write under it, to the commit's waiters, and makes the waiters of later lwbs wait for the txg that frees a failed one (`zl_lwb_error_txg`), since the on-disk chain may end there. On a failed pool that txg is never committed, so every later commit that reaches an lwb falls back to the txg and returns `EIO`.

### Cache flush errors

`zio_flush()` takes a `propagate` argument. The ZIL passes `B_TRUE` for the flushes after an lwb write (`zil_lwb_write_done()`), so a failed flush fails the lwb's root zio and the commit falls back to the txg; label and uberblock flushes pass `B_FALSE`. Without this, a drive that cached an lwb write and then failed the flush would let `fsync()` return 0 for data a power loss could lose.

Two rules keep safe commits from failing. `ENOTSUP` and `ENOTTY` complete the flush as a success and set `vdev_nowritecache`: the device has no write cache. A leaf that can't be written is skipped if its top-level vdev still can be, since the data is also on the writeable siblings; otherwise a degraded mirror or raidz would fail every flush. A lone leaf that took the write and then died still fails it.

### Log writes and `dmu_sync()` on a failed pool

The fence fails lwb writes and the `dmu_sync()` writes of `WR_INDIRECT` records, all `CANFAIL`. A failed `dmu_sync()` write leaves its dirty record `DR_NOT_OVERRIDDEN`, and `dbuf_sync_leaf()`, which waits for a `dmu_sync()` in progress and accepts either outcome (a port of OpenZFS 7316fdd1c0), writes the block like any other dirty block. `dmu_sync_late_arrival()` fails at `dmu_tx_assign()`, and `zfs_get_data()` maps a read error other than `ENOENT` on a `WR_NEED_COPY` record to `EIO` rather than asserting. Either way `zil_lwb_commit()` waits for the txg and leaves the record out.

### Failed `dmu_sync()` writes and space reuse

The ZIL issues an lwb once its `dmu_sync()` writes are ready, not done, so a log block can reach the disk pointing at a block whose write then fails. If `zio_done()` unallocated that space at once, another block born in the same txg, such as another dataset's next lwb, could be allocated there. If the pool then failed or crashed before the txg synced, the import would claim two log records with the same DVA and birth, which the ARC can't tell apart: the claim panics in `arc_hdr_verify_checksum()` or claims the space twice. For a failmode=death pool, failing before the open txgs sync is the normal case.

So `zio_done()` frees a failed allocating write that isn't reexecuted in its own txg (`zio_dva_free_failed()`, onto `spa_free_bplist[]`), as `dmu_sync_late_arrival_done()` already frees its written block in its txg. The space is reused only after that txg syncs, when the record is older than anything the import claims. These are the `CANFAIL` writes; reexecuted writes and dedup children, whose parent shares their block pointer, still unallocate at once. Gang headers and children are freed as plain blocks, so the free doesn't read a header that may never have been written. A failed pool frees nothing (see I/O on a failed pool).

### Closing the log of a failed pool

`zil_close()` on a failed pool calls `zil_failed_close()` instead of committing: the log stays on disk as it was at the failure, and the rest is discarded. A failed pool never resumes, so the log keeps no recovery state. `zil_failed_close()` waits for the lwbs in flight with no deadline (`zil_failed_wait(zilog, 0)`), since an lwb can't be freed under its write, frees every lwb on `zl_lwb_list`, which `zil_sync()` would never clean up since no txg commits, and clears `zl_get_data`. The itxs are freed by `zil_clean()` as their txgs drain, and by `zil_free()`.

`zil_failed_wait(zilog, timeout)` issues the open lwb, if any, which completes in the fence at once, then polls `zl_lwb_list` every 10 ms until no lwb is `LWB_STATE_ISSUED` or `LWB_STATE_WRITE_DONE`. It returns `EBUSY` if some still are at the timeout (0 means none). Only an lwb whose write reached a device before the failure can take long, and the device may never answer.

Callers of `zil_close()` that mustn't wait forever, or that hold locks others need, keep it from waiting: most first call `zil_failed_wait()` with a deadline, so that their later `zil_close()` has nothing to wait for. A file system's wait (`zfsvfs_failed_log_wait()`) holds `z_teardown_lock` as writer, taken with the deadline (`rrm_enter_write_deadline()`, see Detaching file systems), so that it also waits for the vnode operations in progress, which may be waiting for the log writes or adding dirty data, and so that `z_log` can't change; operations that start later can do neither on a failed pool, whose tx assignments and commits fail at once. `zil_failed_wait()` waits for the log's `zl_issuer_lock` only until its deadline too, since a commit can hold it while it waits for a txg (`zil_create()`, `zil_commit_writer_stall()`). The teardown, and a volume's last close, also wait for the dataset's dirty data to drain (`txg_wait_synced()`), and a log write of any file system or volume in the pool holds that up, since a log block holds its txg open until its write is done (`lwb_tx`, committed in `zil_lwb_flush_vdevs_done()`). So `zfsvfs_failed_log_wait()` and `zvol_fail()` then wait for a dirty dataset's txgs until the same deadline (`txg_wait_synced_deadline()`), and return `EBUSY` if they haven't synced. `zvol_fail()` waits once the volume's I/O in progress has finished, after which nothing dirties it before the last close.

- `zfsvfs_detach()` and `zvol_fail()` wait until the export's deadline, so a stuck log write makes the export return `EBUSY` rather than hang, unless a file of the pool going inactive was writing out a page when the pool failed (see I/O that never completes).
- An unmount on a failed pool (`zfs_umount()`) waits until a deadline as long as an export's (`spa_exit_deadline()`), and fails with `EBUSY` if some writes are still in flight then; the file system stays mounted and keeps the pool busy.
- `zfs_suspend_fs()`, for a rollback, online receive or userspace upgrade, doesn't tear a failed pool's file system down at all (see Receive and rollback).
- The last close of a volume on a failed pool fails the volume, repeating `zvol_fail()` until its log writes are done, without holding `zfsdev_state_lock` while it waits (see Last close without `zfsdev_state_lock`).

Two paths can still wait in `zil_close()`, with no deadline, for a log write that never finishes: a rollback, receive or upgrade that suspended its file system before the pool failed, holding `z_teardown_lock` as writer (the export's detach waits for it only until its deadline), and the last close of a volume that `zvol_fail()` refuses (COMSTAR's or the dump device), holding `zfsdev_state_lock` (see Questions from code reading).

### Callers

Every caller of `zil_commit()` other than `zil_close()` returns its error: `zfs_fsync()`, the `FSYNC`, `FDSYNC`, `FRSYNC` and `sync=always` paths of the ZPL, `zfs_putpage()` for `msync(MS_SYNC)`, `zfs_sync()` of one file system, the zvol write paths and the `DKIOCFLUSHWRITECACHE`, `DKIOCSETWCE` and `DKIOCFREE` ioctls, and COMSTAR's `ZVIO_COMMIT` writes. An operation that needs a new tx fails at `dmu_tx_assign()` first, so the commit's `EIO` mostly reaches syncs, flushes, and operations already past their tx when the pool failed.

## File systems

### Detach, not unmount

The export of a failed pool doesn't wait for its file systems to be unmounted. `zfs_ioc_pool_export()` detaches them in the kernel (`zfs_fail_mounts()`), and `zpool export` unmounts them once the pool is gone. Like `zvol_fail_minors()`, `zfs_fail_mounts()` does nothing unless the pool has failed (`spa_failed_by_name()`), so a healthy pool's export is unchanged, and a failmode=death pool that failed by itself takes this path under a plain `zpool export`.

Unmounting first can't be relied on. The unmounts race with the threads the failure wakes: a mount whose log replay was waiting on the pool finishes after `zpool export` has read `mnttab`, and an online receive whose resume fails unmounts its file system itself, so `zpool export`'s own unmount of it fails and `zpool export` gives up with other file systems still mounted. Either way the export returns `EBUSY`. And an unmount's teardown waits with no deadline for the vnode operations in progress, while on a failed pool the unmount itself fails if log writes are still in flight at a deadline (see Closing the log of a failed pool).

### Finding the file systems: `zfs_mounts`

`zfs_mounts` lists the file systems that own their datasets, including snapshots under `.zfs`: those being mounted (`z_mounting`; `zfs_domount()` adds them before log replay) and those mounted, until they are unmounted or detached. `z_spa` stays valid while a file system is listed, since its dataset holds the pool.

`zfs_fail_mounts(pool, deadline)` tries each failed file system of the pool once per call (`z_fail_gen`), skipping those another call is detaching (`z_failing`) and those whose `z_spa` has another name or hasn't failed: the list may hold a newer pool of the same name. `z_failing` keeps the file system from being freed, since `zfs_umount()` waits for it. If only mounts in progress are left, it waits for them until the deadline, and they fail by themselves (see Mounts). It returns how many it detached; Export and unload says how the export uses that count and the deadline.

### Detaching a file system

`zfsvfs_detach()` first waits for the vnode operations in progress, the log writes in flight and its dirty data to drain, until the deadline (`zfsvfs_failed_log_wait()`, see Closing the log of a failed pool), and returns `EBUSY` if any remain; the file system then stays attached and keeps the pool busy. It waits here rather than in the teardown, where `zil_close()` would wait for the log writes with no deadline. The wait takes `z_teardown_lock` as writer with the deadline, as the teardown does (below). A receive or rollback doesn't suspend a failed pool's file system (see Receive and rollback); one that suspended it before the pool failed holds `z_teardown_lock` as writer until it resumes, which it does at once unless its own teardown is waiting for a log write in flight, and then holds up the detach only until the deadline.

It then suspends the file system as a rollback does (`zfsvfs_teardown()` with `unmounting` false), with the export's deadline: close the log, release every znode's dbufs, unregister the property callbacks, wait for the dataset's dirty data to drain, and evict its dbufs. Finally it clears the objset's user pointer, sets `z_os` to `NULL`, drops the teardown locks, takes the file system off `zfs_mounts` and disowns the objset, releasing the pool reference that the export waits for.

Vnode operations hold `z_teardown_lock` as reader from `ZFS_ENTER()` to `ZFS_EXIT()`, including across `uiomove()`, which can sleep in a page fault for as long as the paged file's device takes. So the detach takes the lock as writer with `rrm_enter_write_deadline()`, which gives up at the deadline, first in `zfsvfs_failed_log_wait()` and again in the teardown: an operation asleep outside the pool, such as a read into a mapped page of a file on a hung device, then makes the detach return `EBUSY`, and the file system stays attached. Both take at least a tick, even past the deadline, as in the export's second round of a pool that had failed before the export began: the first so that an `fsync()` that the last log writes woke can return, the second for operations that started in between, which fail at once on a failed pool. Giving up, `rrw_enter_write_deadline()` clears `rr_writer_wanted` and wakes the readers queued behind it, and `rrm_enter_write_deadline()` releases the locks it had already taken, so operations that queued behind the detach wait no longer than the deadline.

### A detached file system

A detached file system has no objset but stays mounted, like one whose resume failed. `ZFS_ENTER()` fails with `EIO` when `z_os` is `NULL`, so every vnode and VFS operation that calls it fails with `EIO`, `statvfs()`, `VOP_PUTPAGE()` and `VFS_SYNC()` included, as does a remount. The few paths that use `z_os` outside `ZFS_ENTER()` (`zfsvfs_hold()`, `zfs_fsync()`, and the rollback, receive and userspace-upgrade ioctls) check it or read it only after entering or suspending the file system.

Its znodes have no SA handles, so `zfs_inactive()` frees each as its last hold goes away, as after an unmount under open files. A forced unmount of it always succeeds: `zfs_umount()` and the teardown skip the objset when `z_os` is `NULL`, and `zfsctl_umount_snapshots()` looks up `.zfs/snapshot` with `gfs_vop_lookup()`, avoiding `ZFS_ENTER()`. One `.zfs` operation, `zfsctl_snapdir_mkdir()`, reads `z_os` without `ZFS_ENTER()` and dereferences `NULL` on a detached file system; its fix is going upstream separately and is not on this branch (see Known limitations and open issues).

### Mounts

`zfs_domount()` fails a mount on a failed pool with `EIO` before adding it to `zfs_mounts`. If the pool fails during the mount, for example during log replay, whose errors `zfsvfs_setup()` ignores, `zfs_domount()` checks again under `zfs_mounts_lock` when it is done and fails the mount, rather than leave a file system for the waiting `zfs_fail_mounts()` to detach. A mount that fails after `zfsvfs_setup()`, usually in reading an uncached root znode, is torn down as an unmount would be (`zfsvfs_teardown()` with `unmounting` set, `zfsctl_destroy()`), since setup opened the log and registered the property callbacks.

### Receive and rollback

An online receive or rollback suspends the mounted file system (`zfs_suspend_fs()`) and reopens it (`zfs_resume_fs()`), as does a userspace upgrade. On a failed pool `zfs_suspend_fs()` returns `EIO` at once and tears nothing down: nothing can be rolled back, received into or upgraded there, and the teardown could wait with no deadline for log writes in flight while holding or queued for `z_teardown_lock` as writer, which the export's detach would then wait for too, rather than return `EBUSY` at its deadline. It reads `z_os` under `z_teardown_lock` as reader, which keeps the objset, and so the pool, held unless an unmount has let go of it. If the pool fails while a file system is suspended, the reopen fails unless the newly received objset and the dataset's properties are cached; a checksum error in a property ZAP does the same on a healthy pool. If `dmu_objset_from_ds()`, `zfsvfs_init()` or `zfsvfs_setup()` fails, `zfs_resume_fs()` gives the file system up: it sets `z_os` to `NULL`, takes it off `zfs_mounts`, disowns the dataset and forces an unmount. `zfsvfs_setup()` fails before it opens the log or sets the objset's user pointer, so nothing else needs undoing. If the forced unmount can't lock the covered vnode, the file system stays mounted with no objset, like a detached one.

### Dirty pages

When the last hold on a file goes away, `zfs_inactive()` writes its dirty pages. On a failed pool those writes fail (`zfs_putapage()`'s tx assign returns `EIO`), as they can on a healthy pool over quota (`EDQUOT`). `zfs_inactive()` then discards the pages, as a forced unmount does, and logs it with `zfs_dbgmsg()`: nothing has the file open or mapped, so there is nobody to tell. Keeping them would leave the znode with no holds and the file system busy, and a later forced unmount or detach would assert in `zfsvfs_teardown()` that the znode is held.

`zfs_inactive()` writes and logs pages holding only `z_teardown_inactive_lock`, not `z_teardown_lock`, so `zfsvfs_teardown()`, for any forced unmount, rollback, receive or detach, sets `z_log` to `NULL` under `z_teardown_inactive_lock` as writer before closing the log. A page write already under way is logged first; a later one isn't logged, and the teardown waits for its txg. The lock isn't held across `zil_close()`, because the vnodes `zil_close()` looks up go inactive in the pool's vnrele taskq (`zfs_get_done()`), which would block on it. Taking it here adds a window to a pre-existing deadlock with removing a file that has extended attributes (see Known limitations and open issues).

### Inactive and unlinked files

The inactive paths handle `dmu_tx_assign()`'s `EIO` on a failed pool as they handle `ENOSPC`. `zfs_inactive()` skips the atime update, and `zfs_rmnode()` and `zfs_purgedir()` leave the file in the unlinked set and free the znode in memory. The unlinked set is processed at the next mount after the pool is imported again. A tx assigned before the pool failed can find the unlinked set's ZAP uncached, so `zfs_unlinked_add()`, for an unlink or a last close, and `zfs_rmnode()`'s removal from the set accept the ZAP update's error on a failed pool, whose disks the update would never reach.

### Stacked mounts

A mount on a directory inside a failed pool's file system, such as a tmpfs, a lofs mount or a zone's `/proc`, doesn't keep the pool from being exported. The file system under it is detached all the same, and `zpool export`'s forced unmount of it then succeeds, since a forced ZFS unmount doesn't check for busy vnodes; the stacked mount stays, unreachable. The export doesn't stop zones or wait for them.

### Unmounting after the export

For a failed pool, `zpool_disable_datasets()` only unshares the file systems, and after the export `zpool_unmount_detached()` force-unmounts those whose `statvfs()` fails with `EIO` (see Userland). Mountpoint directories are left in place, since whether to remove one depends on properties a failed pool can't read.

## Volumes

### Failing a volume

An open volume holds its objset, which would keep a failed pool from being exported until every consumer closed it. `zfs_ioc_pool_export()` therefore calls `zvol_fail_minors()`, which, if the pool has failed, fails the pool's open volumes and volume snapshots (`zvol_fail()`), removes the minors of the closed ones, and returns the number it failed. The last close of a volume on a failed pool calls `zvol_fail()` too (see Last close without `zfsdev_state_lock`).

`zvol_fail()` does what the last close would do while the volume stays open. It sets `ZVOL_FAILING`, which stops new I/O, and drops `zfsdev_state_lock`, which every zvol open, close and ioctl needs. Without it, and only until its deadline (the export's, or one as long for a last close), it waits for the zero thread of a raw volume, which it asks to stop (`zv_zero_exit_wanted`); for the log writes in flight (`zil_failed_wait()`); for the I/O in progress, by polling `rw_tryenter()` on `zv_io_lock` as writer and letting go at once, since `zfsdev_state_lock` comes first in the lock order; and then for its dirty data to drain (`txg_wait_synced_deadline()`), which another dataset's log write can hold up.

With `zfsdev_state_lock` and `zv_state_lock` held again, it replaces `ZVOL_FAILING` with `ZVOL_FAILED` in one step, so I/O never sees neither flag, and calls `zvol_last_close()`: close the log, free a raw volume's DVA map, release the dnode, wait for the dirty data to drain, evict the dbufs and disown the objset. If a wait reached the deadline, it clears `ZVOL_FAILING` and returns `EBUSY`, and the volume keeps the pool busy. If the last open went away meanwhile, it does the last close itself and returns `ENXIO`, and `zvol_fail_minors()` removes the minor.

### Volume states

| Flag | Meaning | Effect |
|---|---|---|
| `ZVOL_FAILING` | `zvol_fail()` is waiting without `zfsdev_state_lock`. Changed with both `zfsdev_state_lock` and `zv_state_lock` held, so either lock is enough to test it. | New I/O and first opens fail, `zvol_remove_zv()` refuses the volume, a last close leaves its work to `zvol_fail()`, and COMSTAR can't take it. |
| `ZVOL_FAILED` | The pool failed while the volume was open, and `zvol_fail()` let go of it, for the export or at the last close. | No objset, dnode, log or DVA map; the minor stays until the last close. |
| `ZVOL_EXTERNAL` | COMSTAR holds pointers into the open volume (objset, log, dnode, range lock) from `zvol_get_volume_params()`. Cleared at the last close. | `zvol_fail()` refuses the volume. |

The I/O paths hold `zv_io_lock` as reader while they use the objset, dnode, log or DVA map (`zvol_io_enter()`, which fails with `EIO` if either failure flag is set).

### I/O and ioctls on a failed volume

| Operation | Result |
|---|---|
| Open | `ENXIO`, also for a volume being failed whose last open has gone |
| `zvol_strategy()`, `zvol_read()`, `zvol_write()` | `EIO` |
| `DKIOCFLUSHWRITECACHE`, `DKIOCSETWCE` disabling the cache, `DKIOCFREE`, `DKIOCDUMPINIT` | `EIO` |
| `DKIOCDUMPFINI` | 0, a no-op: `zvol_fail()` refuses a dump volume, so a failed one isn't `ZVOL_DUMPIFIED` |
| `DKIOCRAWVOLSTATUS`, `DKIOCRAWVOLSTOP` | `ENOTSUP`: the last close cleared `ZVOL_RAW` |
| `DKIOCINFO`, `DKIOCGMEDIAINFO(EXT)`, `DKIOCGETEFI`, `DKIOCGETWCE`, `DKIOC_CANFREE` | Answered from in-core state |
| `zvol_dump()` | `EIO`; it can't take `zv_io_lock` in panic context, but nothing changes then |
| `zvol_get_volume_params()` (COMSTAR) | `ENXIO`, also while the volume is being failed or once its pool has failed |

A volume not yet failed on a failed pool fails its own I/O: `dmu_tx_assign()` returns `EIO`, uncached reads fail, and raw I/O checks `spa_failed()`. A first open on a failed pool, and `zvol_create_minor()`, return the error of the reads that can fail there (the `readonly` property for an open, the volume's dnode for a minor) before they set anything up, including when the pool fails while they wait for it.

### When the state and the minor go away

`zvol_fail_minors()` removes the minors of closed volumes at once. A failed volume's `zvol_state_t` and minor stay while it is open, and `zvol_close()` removes them at the last close, which on a failed pool fails a volume that the export hasn't; after a successful export, `zvol_remove_minors()` removes any closed ones left. `zvol_minor_lookup()` skips failed volumes, so importing a pool of the same name creates new minors while the old ones wait for their last close.

### Volumes the export can't fail

`zvol_fail()` refuses (`EBUSY`) a volume that COMSTAR holds (`ZVOL_EXTERNAL`) or that is the dump device (`ZVOL_DUMPIFIED`), and the export returns `EBUSY` until it is released. `zpool export -F` won't fail a pool with such a volume, or a swap volume, in the first place (`zvol_pinned_minors()`; see Failing a pool from userland). The check doesn't wait for `zfsdev_state_lock`, so it can miss a dump volume that is being set up (see Questions from code reading). It skips failed volumes, which hold no pool, such as the swap volume of an earlier pool of the same name, failed by that pool's export and still held by swap. A failmode=death pool that fails by itself has no such choice. Its COMSTAR and dump volumes keep it from being exported, and its dump volume's I/O, a crash dump included, gets `EIO`. A plain export fails its swap volume like any other, although `-F` of the same failed pool returns `EBUSY` for it (see Questions from code reading).

### Raw volumes

Raw volumes are stlouis-only (the `rawvol` property). Their blocks are preallocated and zeroed by `zvol_zero_thread()`, which holds an extra open (`OTYP_INITIALIZING`) while it runs, and their I/O goes straight to the vdevs (`vdev_op_rawio`) through a block-to-DVA map (`zv_dvas`), without zios.

On a failed pool the zero thread's tx assign fails, so it stops at once when `zvol_fail()` asks. A chunk whose tx was assigned before the failure is dropped by `dmu_zero()` if its blocks can't be held (see Poisoned reads). Because it closes its open without `zfsdev_state_lock`, `zvol_fail()` and `zvol_remove_zv()` recheck `zv_total_opens` under `zv_state_lock`.

Since the fence doesn't see raw and dump I/O, `zvol_rawio()` and `zvol_dumpio()` check `spa_failed()` themselves and return `EIO`, the first under `SCL_STATE` as reader and the second before it takes that lock. `spa_fail()` doesn't take `SCL_STATE`, so neither check is ordered against the failure. `zvol_raw_strategy()` splits a request into chunks of at most `zvol_maxphys` that never cross a volblocksize boundary, and checks and issues each in turn (`ldi_strategy()`, or `ldi_ioctl(DKIOCFREE)` for a TRIM), so a chunk that passed the check just before the failure is still issued after it, and the request's later chunks fail with `EIO`, leaving it partly done; a dump write can race the same way.

These writes land only in the volume's preallocated, already-synced blocks (`zv_dvas`), never in pool metadata; preallocation zeroing goes through `dmu_zero()` and the fence. Raw I/O holds `zv_io_lock` as reader across each chunk's `biowait()`, so once `zvol_fail()`'s `rw_tryenter()` succeeds, none of the volume's raw I/O is in flight, and raw I/O that the driver never completes makes `zvol_fail()`, and so the export, return `EBUSY`. `zvol_last_close()` frees the DVA map and clears `ZVOL_RAW`.

### Last close without `zfsdev_state_lock`

The last close of a volume with dirty data waits for it to sync, and `zvol_close()` holds `zfsdev_state_lock` across the close. So when a close looks like the last one, `zvol_close()` first waits for the dirty data without that lock. Its own open keeps the volume from being closed or removed meanwhile; if another open comes in, the wait was merely unnecessary. A failed volume skips the wait.

Otherwise a last close on a suspended pool (failmode `wait` or `continue`) would sleep holding `zfsdev_state_lock` until the pool resumed, blocking every zvol open, close and ioctl, and the export's `zvol_fail_minors()`. On a healthy pool with slow I/O, the same wait stalls opens of unrelated volumes for seconds. The early wait covers only the dataset's dirty data: `zil_close()`'s own waits, and `zvol_last_close()`'s wait for what is dirtied meanwhile, still run under the lock, as does a volume's first open while it reads the pool (see Questions from code reading).

On a failed pool, `zil_close()` waits with no deadline for the log writes in flight (see Closing the log of a failed pool), so the last close fails the volume instead (`zvol_fail()`), which waits for them without `zfsdev_state_lock`. If they are still in flight at its deadline, `zvol_fail()` leaves the volume open and not failed, and the close calls it again, until it succeeds: the close returns only once the writes are done, but other opens, closes and ioctls run meanwhile. The close then removes the failed volume. A volume that `zvol_fail()` refuses (COMSTAR's or the dump device) is closed as on a healthy pool, waiting in `zil_close()` under the lock, and one that `zvol_fail()` is already failing is left to it.

## Send, receive and diff

### Why a blocked stream keeps a failed pool from exporting

A send, receive or diff moves its stream through a file descriptor that the caller passes in, usually a pipe, and holds its dataset, and so a `spa_refcount` reference on the pool, while it runs. If the process at the other end (for a diff, a reader thread in the `zfs` command itself, since libzfs creates the pipe) stops reading (send, diff) or writing (receive), the stream's thread sleeps in `vn_rdwr()`. Failing the pool doesn't wake it, so unless the export breaks it out of that sleep, the export's wait for holders (`spa_export_failed_wait()`) reaches its deadline and returns `EBUSY`.

The thread that sleeps on the descriptor is always the ioctl's own thread (in `dump_bytes()`, `receive_read()` or `write_record()`). The send's `send_traverse_thread` and the receive's `receive_writer_thread` only touch the pool: the first ends when the ioctl's thread cancels the queue between them, and the second fails with `EIO` once the pool has failed.

### The stream registry

Each pool keeps its streams in progress on `spa_streams`, a list of `spa_stream_t` protected by `spa_streams_lock`. A `spa_stream_t` records the pool, the thread that reads or writes the descriptor (`curthread` when it registers) and the flag `ss_cancelled`. It is embedded in the stream's own state, so registering allocates nothing.

A send registers in `dmu_send_impl()`, a receive in `dmu_recv_stream()` and a diff in `dmu_diff()` (`spa_stream_register()`), each once it holds its dataset and before it touches its descriptor, and each unregisters (`spa_stream_unregister()`) before it releases the dataset. `dmu_recv_stream()` is the only part of a receive that reads the descriptor: libzfs reads the BEGIN record itself and passes it in `zc_begin_record`, and `dmu_recv_end()` only runs sync tasks, which return `EIO` on a failed pool. `spa_stream_register()` puts the stream on the list and then returns `EIO` if the pool has failed, so a stream that starts between two passes of the export is either seen by the next pass or doesn't start; it is unregistered either way.

The lock order is `spa_namespace_lock`, then `spa_streams_lock`, then the stream thread's dispatcher lock: `spa_export_failed_wait()` calls `spa_streams_cancel()` with `spa_namespace_lock` held, and `spa_streams_cancel()` calls `thread_abort_sleep()` with `spa_streams_lock` held. The lock also keeps a listed thread alive: a stream unregisters under it before its ioctl returns, so a thread found on the list can't exit until `spa_streams_cancel()` drops the lock. `ss_cancelled` is set under the lock and read without it; it only goes from false to true, and a stream that reads it stale is caught by the next pass.

### Waking a blocked stream

On each pass of its poll (every `MAX(hz / 10, 1)` ticks until the export's deadline), `spa_export_failed_wait()` calls `spa_streams_cancel()`, which sets `ss_cancelled` on each of the pool's streams and calls `thread_abort_sleep()`, a new genunix function in `sig.c`, on its thread. Under `thread_lock(t)`, if the thread is in an interruptible sleep (`ISWAKEABLE(t)`), it sets `ttolwp(t)->lwp_sysabort` and makes the thread runnable with `setrun_locked()`; it leaves alone a thread that has no lwp or is running, stopped or asleep uninterruptibly. `/proc` aborts a system call the same way for `PRSABORT`. The interruptible sleep primitives (`cv_wait_sig()`, `cv_wait_sig_swap()`, `sema_p_sig()` and the like) clear `lwp_sysabort` as they go to sleep and return as interrupted if it is set when they wake. Pipes, FIFOs, sockets and STREAMS sleep in them, so the aborted read or write returns `EINTR` or a short count to `vn_rdwr()`, and the stream takes its existing error path.

This is safe. It affects only sleeps that a signal could interrupt, whose callers already handle an interrupted return; a sleeper that ignores `lwp_sysabort` sees a spurious wakeup. It posts no signal, so the process's signal state is untouched and nothing kills or stops it. It doesn't persist: an abort aimed at a thread that isn't asleep sets nothing, and the sleep primitives clear `lwp_sysabort` as each sleep starts and ends. And `spa_streams_lock` keeps the thread from exiting. An abort misses a stream that is between sleeps; the stream's own checks of `ss_cancelled`, and the cancel repeated on every pass, cover that. In libzpool, `spa_streams_cancel()` only sets the flags.

### Cancellation checks and the error

A stream checks `spa_stream_cancelled()` after each read or write of its descriptor (`dump_bytes()`, `receive_read()`, `write_record()`), and once per record (for a diff, once per block visited) next to the existing `issig()` check (`dmu_send_impl()`, `dmu_recv_stream()`, `diff_cb()`). The first catches an aborted call however it ended: a FIFO returns `EINTR`, but another type of descriptor can return a short count with no error, which `dump_bytes()` and `write_record()` would otherwise treat as success. The second stops a stream that isn't blocked at its next record.

`spa_stream_unregister()` turns any nonzero error from a cancelled stream into `EIO`, because the error can arrive as `EINTR` (`dump_record()`), as `ECKSUM` (`receive_read()`, for a read that moved nothing), or as the traverse or writer thread's own error. `EIO` is what everything else on a failed pool returns; `EINTR` would claim that the command was interrupted, and `ECKSUM` would make `zfs receive` suggest resuming an incomplete stream, the wrong advice for a pool that is going away. A resumable receive (`zfs receive -s`) keeps the partial state that the pool committed before it failed, and resumes from its token after the pool is imported again.

### What still returns EBUSY

`thread_abort_sleep()` doesn't wake a stream whose own process is stopped, by job control or through `/proc` (`TS_STOPPED`), or one asleep uninterruptibly, for example writing its stream to a file on another, suspended pool, which is hung I/O outside the scope of this design. A stopped process at the other end of a send's or receive's pipe is not this case: the stream's thread sleeps interruptibly and is woken. In both cases the export returns `EBUSY` at its deadline, the pool stays failed, and the export can be run again. A stopped stream whose process continues before the deadline is aborted by the next pass, and one that continues later by the next export run.

### Rejected: signals

Posting a signal to the stream's thread (`SIGINT`, plus `SIGPIPE` for a send or diff) needs no genunix change, but it doesn't reliably free the stream and it has side effects. An ignored signal is discarded when posted (`sig_discardable()`, for a single-threaded process) or when the woken thread checks for signals (`issig()`), and `eat_signal()` doesn't wake a sleeper for a blocked one, so a process that ignores or blocks both is never freed; Rust programs, for example, ignore `SIGPIPE`. A delivered signal's default action kills the `zfs` command rather than letting it report the error, and would disrupt a program that calls libzfs in-process. `thread_abort_sleep()` is short and independent of ZFS, and can be reviewed in illumos-gate as general infrastructure; ZFS could set `lwp_sysabort` itself, but `klwp_t` internals belong to genunix.

### Porting to OpenZFS

Everything except the wake-up is common code: the registry, the cancellation checks and the `EIO`. The wake-up would be a per-platform hook beside the `zfs_file_*` code, which might use `sleepq_abort()` on FreeBSD and `task_work_add(..., TWA_SIGNAL)` on Linux 5.11 and later; neither has been implemented or verified on those platforms.

## Userland

### zpool export -F

`zpool export -F` fails each named pool, whatever its state, and exports it, discarding what the pool hasn't synced; synchronous writes already in the intent log are replayed at the next import. `-F` implies `-f`. `zpool_do_export()` and `zpool_export_one()` (`usr/src/cmd/zpool/zpool_main.c`) work in this order:

1. Find the root pool, from the ZFS `mnttab` entry for `/` (`root_pool_name()`).
2. For every named pool except the root pool, call `zpool_force_exit_name()` (`ZFS_IOC_POOL_FORCE_EXIT`), ignoring errors. This comes before any pool is opened, because opening a pool takes `spa_namespace_lock`, which a command sleeping on a suspended pool can hold until the pool fails.
3. Open each pool. `zpool_export_one()` refuses the root pool ("pool holds the root file system"), then calls `zpool_force_exit()`, which repeats the ioctl and reports any error. `EBUSY` here means that the pool has a volume in use as a dump or swap device or by COMSTAR (see Failing a pool from userland), and the pool is left as it was.
4. Call `zpool_disable_datasets()`. It refreshes the config, and if `ZPOOL_CONFIG_FAILED` is present, it unshares the pool's file systems and leaves them mounted.
5. Call `zpool_export_force()`: `ZFS_IOC_POOL_EXPORT` with `zc_cookie` (force) and `zc_guid` (hardforce) set. The kernel fails the pool again (`zfs_pool_fail()`), detaches its file systems, fails its volumes and exports it (see Export and unload).
6. Call `zpool_unmount_detached()`, which forcibly unmounts (`umount2(MS_FORCE)`) the pool's file systems that are still in `mnttab` and whose `statvfs64()` fails with `EIO`, nested ones first, retrying for up to 5 s while `umount2()` returns `EBUSY`, which a process looking up paths in the file system can cause. If any are left, `zpool` prints "warning: N file system(s) of 'tank' are still mounted, and fail with EIO until they are unmounted", and still exits 0 (see File systems for the mountpoint directories).

Failing a failed pool does nothing, so the pool is failed in four places. The by-name call needs no pool handle, so it doesn't wait for `spa_namespace_lock`, but it reports nothing; `zpool_force_exit()` reports errors; the export ioctl's own call covers libzfs consumers that call `zpool_export_force()` alone; and `spa_export_common()` fails a pool whose import was still in progress, which the by-name calls leave alone, once `spa_lookup()` has waited for the import.

The pool fails before anything is unmounted because an unmount on a suspended pool waits in `zil_commit()` for the pool to resume, and one on a healthy pool waits for its log writes. Why the file systems are then detached in the kernel rather than unmounted by `zpool` is explained under File systems.

In illumos-gate, `-F` is an undocumented flag that skips the label and cache-file update; here it fails the pool. Tests that need the old effect set the `spa_export_skip_update` tunable instead (see Export and unload).

### zpool export -a

`zpool export -a` exports every imported pool in parallel, except the root pool, which can't be exported; trying would unmount every file system in it that isn't busy.

With `-F`, listing the pools would take `spa_namespace_lock`, so `zpool_force_exit_all()` fails them first, finding them through their `zfs:0:<pool>` I/O kstats and skipping the root pool and names that start with `$`, such as the temporary name used by `zpool import`. A kstat name is cut off at `KSTAT_STRLEN - 1` characters, so a name that long is passed with the prefix flag (`zc_cookie`), and the kernel fails every pool whose name starts with it, except those that `zfs_pool_fail()` refuses.

### Export without -F

`zpool export` or `zpool export -f` of a suspended pool fails at once. `zpool_export_one()` checks `zpool_get_status()` for a suspended status and prints "pool is suspended; use '-F' to discard unsynced changes" without unmounting anything, since an unmount would wait for the pool. If the pool suspends after that check, the kernel returns `EAGAIN` (see Export and unload), and libzfs prints the same message. The pool stays suspended and can still resume.

A pool that has already failed (health `FAILED`) is removed by a plain `zpool export`, as well as with `-f` or `-F`; only a pool with an active shared spare needs `-f` (see Failed and hard-forced exports). Without `-F`, steps 4 to 6 run with `zpool_export()` in place of `zpool_export_force()`, and the kernel detaches, fails and waits in the same way.

If the export of a failed pool returns `EBUSY` ("pool is busy"), the pool stays failed, and the command can be run again, with or without `-F`, with a new deadline. Open files don't cause `EBUSY`, since the kernel detaches a busy file system. What can hold a failed pool past the deadline is a send, receive or diff whose process is stopped or asleep uninterruptibly; a file system or volume still waiting for its log writes or I/O in flight; a file system with a vnode operation in progress that is asleep outside the pool, such as a read into a mapped page of a file on a hung device; a volume held by COMSTAR or used as the dump device; a fault-injection handler (`spa_inject_ref`); or I/O that the driver never completes and that keeps a dataset referenced. Other I/O that never completes blocks the export without a deadline (see I/O that never completes).

### Reporting a failed pool

`spa_get_stats()` adds `ZPOOL_CONFIG_FAILED` ("failed", a boolean that isn't stored on disk) to a failed pool's config, and omits `ZPOOL_CONFIG_ERRCOUNT`, since the error log can't be read. libzfs's `check_status()` returns `ZPOOL_STATUS_FAILED` for such a config before any other check, so a failed pool, which isn't suspended anyway, never shows a suspended status. (`check_status()` also checks for suspension before resilvering, so a pool that suspends during a resilver shows as suspended.) `ZPOOL_STATUS_FAILED` comes after `ZPOOL_STATUS_BAD_LOG`, among the statuses that have message IDs, because `zfs_msgid_table` is indexed by the enum; that renumbers the later statuses, which a private interface built with its consumers allows.

`zpool status` of a failed pool shows:

```
 state: FAILED
status: The pool has failed: it can no longer write to its devices, and
	the changes it had not written when it failed have been lost.
action: Export the pool, make sure its devices are working, then import
	it again.
   see: http://illumos.org/msg/ZFS-8000-LR
```

followed by the config and "errors: Unknown, the pool has failed". The `health` property (`zpool list`, `zpool get health`) is `FAILED` whenever the config has `ZPOOL_CONFIG_FAILED`.

`zpool get` of a failed pool never shows a value that might be wrong. The kernel doesn't read a failed pool's property object, which may or may not be cached (`spa_prop_get_failed()`). It reports from memory the properties it also keeps in the `spa_t` (`delegation`, `failmode`, `autotrim`, `autoexpand`, `multihost`, `dedupditto`), the ones that come from the config as usual, and the rest as unknown (source `ZPROP_SRC_NONE`, no value), which `zpool get` shows as "-" with source "-". Feature states come from the `spa_t`'s refcount cache (`spa_add_feature_stats()`).

### zpool destroy, clear and set

A destroy writes labels, which a failed pool can't do. `zpool_do_destroy()` checks for `ZPOOL_CONFIG_FAILED` before it unmounts anything, and `zpool_destroy()` fails with "pool has failed, and can't be marked destroyed; use 'zpool export -f' to remove it", although a plain `zpool export` removes it too (see Questions from code reading). If the pool fails after `zpool` read its config, the kernel refuses with `EIO` ("cannot destroy 'tank': I/O error"; see Pool state and failure).

`zpool clear` of a failed pool fails with `EIO` ("cannot clear errors for tank: I/O error"): `zfs_ioc_clear()` refuses the pool before it clears any error counts or reopens any device. `zpool set` fails with `EIO`, like any other change, except `zpool set cachefile`, which `zfs_ioc_pool_set_props()` handles without the pool. Setting `failmode=death` is described under Pool state and failure.

### libzfs, the zfs command and zpool(8)

libzfs exports `zpool_force_exit()`, `zpool_force_exit_name()` and `zpool_unmount_detached()`, and adds `ZPOOL_STATUS_FAILED` and `EZFS_EXPORT_IN_PROGRESS` ("pool export in progress", for the `ZFS_ERR_EXPORT_IN_PROGRESS` of a second export of a pool already being exported). `zpool_get_errlog()` returns -1 when the config has no error count. `zpool_enable_datasets()` mounts the file systems it found even if iterating the pool fails partway, as it does when the pool fails, and returns the error. libzfs_core is unchanged.

The `zfs` command changes in one place: since a detached file system can't be opened by dataset name once its pool is gone, `zfs unmount <path>` (`unshare_unmount_path()`) unmounts a path whose `stat()` fails with `EIO` and that `mnttab` lists as a ZFS mountpoint.

`zpool(8)` documents `-a` and `-F`, the `FAILED` health, `failmode=death` and that a failed pool can't be destroyed. Its example of what can make the export of a failed pool fail is a send or receive that is stopped and can't be woken.

## FMA

### Ereports

`spa_fail()` posts one `ereport.fs.zfs.io_failure` after it has marked the pool failed. `zfs_ereport_start()` adds `pool_failed` (`FM_EREPORT_PAYLOAD_ZFS_POOL_FAILED`, boolean true) to every ereport from a failed pool, and sets `pool_failmode` to `death` (`FM_EREPORT_FAILMODE_DEATH`) for a `failmode=death` pool. A failed pool's I/O posts nothing else from `zio_done()` (see Reports, under I/O on a failed pool), and a load that returns an error on a failed pool doesn't post the ereport that a failed load usually posts (see A pool that fails while it loads).

A `failmode=death` pool fails where it would otherwise suspend, and `zio_suspend()` then returns before posting the suspension's `io_failure`, so the pool posts only the failure's. A `wait` or `continue` pool that suspends and then fails (`zpool export -F`, or arming at reboot) posts both: the suspension's, without `pool_failed`, and the failure's, with it.

A failing write posts its `io` and `data` ereports only for its first and last attempts, not for the reexecutions in between (see Retry cap, under I/O on a failed pool). Otherwise a disk that fails every write posts a few thousand ereports per failure, which overflows zfs-diagnosis's event queue (fmd's `client.evqlim`, 256 by default); fmd then drops the `io_failure` ereport, and the failure goes undiagnosed.

### Diagnosis

zfs-diagnosis (`zfs_de.c`) diagnoses an `io_failure` ereport that has `pool_failed` set as `fault.fs.zfs.pool_failed`, whatever `pool_failmode` says. This check comes before the failmode-based diagnosis as `fault.fs.zfs.io_failure_wait` (ZFS-8000-HC) or `fault.fs.zfs.io_failure_continue` (ZFS-8000-JQ), whose advice, `zpool clear`, can't recover a failed pool. If the pool's case is already solved, because the pool suspended before it failed, `zfs_fm_recv()` closes that case and diagnoses the failure in a new one; a pool fails only once per import, so this happens at most once.

zfs-retire acts only on device faults, so it ignores the new fault. The export posts `ESC_ZFS_pool_destroy`, on which zfs-diagnosis closes the cases of pools that are gone (`zfs_purge_cases()`), so the fault clears when the failed pool is exported.

`fault.fs.zfs.pool_failed` is code 19 in `usr/src/cmd/fm/dicts/ZFS.dict` (illumos-gate's ends at 18), message ID ZFS-8000-LR, which `ZFS.po` gives type Error and severity Major; its description and impact say that the pool can no longer write to its devices, its unwritten changes are lost and it can only be exported, and its action is the one `zpool status` prints. The code and message ID are not yet agreed with upstream (see Known limitations and open issues).

### zfs-diagnosis fixes

Two zfs-diagnosis bugs that forced-exit testing exposed are fixed in their own commits, ahead of the feature and independent of it.

"zfs-diagnosis leaks pool handles": `zfs_fm_recv()` closes the handle that `find_pool()` returns on the path that gives up (`pool_drops`) as well as on the usual one. A leaked handle carries copies of the pool's config and property nvlists, and repeated failure tests grew the 32-bit fmd until it aborted.

"zfs-diagnosis can fault a device of a pool for errors from before its import": zfs-diagnosis closes a pool's cases on the export's `ESC_ZFS_pool_destroy`, but its queue can lag behind a quick export and import, the usual way to recover a failed pool. The purge then keeps the case, and its remove timer or a stale ereport solves it against the new import, so zfs-retire faults a healthy device. Each case therefore records the time of its latest ereport (`zc_last`), and `zfs_case_solve()` closes rather than solves a case whose ereports all predate the pool's current load time (`zfs_case_predates_load()`). Using the latest ereport rather than the first keeps a new ereport that joins an old case diagnosed. Opening a new case for the new ereport instead was rejected, because the two cases' SERD engine names would collide. A case restored when fmd starts has no ereport times and isn't checked; the remaining gaps are under Known limitations and open issues.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Upstream base | Port OpenZFS's suspend-aware waits (`txg_wait_synced_flags()`, `DMU_TX_SUSPEND`), failable `zil_commit()`, ZIL write-error handling in txg sync and parallel import and export; not the ZIL crash/resume series. | The waits are small, tested upstream, and keep later ports mechanical. A failed pool never resumes, so it needs none of the crash/resume state machine, which would roughly double the review (see Waits, ZIL). |
| `failmode=death` | A new failmode, on-disk value 3, that fails the pool wherever it would suspend, ENOSPC included. | Oxide's U.2 pools are single-disk, so a suspended pool never resumes and wedges whatever touches it. ENOSPC gets no exception because a suspended pool can't free space (see Pool state and failure). |
| `-F` fails at once | `zpool export -F` fails the pool whatever its state, healthy included, and never tries a normal export first. | Trying first makes the outcome depend on whether the pool can sync, and can wait without bound on a slow drive. Failing at once always leaves the last committed txg plus the intent log; a mistaken `-F` loses seconds of asynchronous writes (see Failing a pool from userland). |
| Arming | Only at reboot (`spa_shutdown_callb()`) and in ztest. | At shutdown a healthy pool should still sync, but unmounting a file system of a suspended pool would hang the reboot. Anywhere else, arming makes the outcome depend on whether the pool would sync (see Pool state and failure). |
| Failing without `spa_namespace_lock` | `ZFS_IOC_POOL_FORCE_EXIT` finds the pool under the leaf lock `spa_namespace_avl_lock` and holds it with `spa_exit_hold()`. | A thread asleep on the pool can hold `spa_namespace_lock` for good. A lockless walk of the tree (as in openzfs/zfs#11082) can misread it, and fixing only the known sleepers leaves the next one a regression away (see Failing a pool from userland). |
| Void fence | Reads and `CANFAIL` writes get `EIO`; other writes, flushes and TRIMs succeed without I/O; allocating writes get fake DVAs; frees and claims do nothing. | The disks stay at the last committed txg even if the drive comes back (fencing only labels wouldn't), and reads don't wait on a dying drive. Syncing context needs error handling only for reads; durability comes from pool state, never from a zio's result (see I/O on a failed pool). |
| Drain, don't abandon | The sync thread keeps syncing into the fence; what it can't complete is discarded per txg and at unload. | The normal sync paths release the holds dirty data has. Abandoning the sync thread would strand threads holding `z_teardown_lock`, range locks and SCL locks, and undirtying DMU state by hand would need new code in dbuf and dnode internals (see Syncing context). |
| Read errors in syncing context | Syncing context on a failed pool gets zeros for a block it can't read (`dbuf_poison()`); the remaining sites were found by testing. | Auditing every read site, as openzfs/zfs#11082 does with checks at hundreds of sites, costs much more review for code that the fence and poisoning make unreachable (see Syncing context). |
| Reads on a failed pool | Metadata comes from memory or fails, never a default; user data comes only from cached dbufs and the page cache. | A `zfs list` that silently drops datasets, or a property shown at its default, would mislead sled-agent. Whether cached user data should be readable is open (see Known limitations and open issues). |
| Retry cap | A failing allocating write is reexecuted at most `zio_reexecute_max` (100) times, then suspends or fails the pool; only its first and last attempts post ereports. | Without the cap, a disk that fails writes but answers probes keeps the pool retrying forever. An ereport per retry can overflow fmd's queue and lose the `io_failure` ereport (see I/O on a failed pool, FMA). |
| Hung I/O | Out of scope: forced exit doesn't cancel I/O a driver already has. The export returns `EBUSY` at its deadline if that I/O keeps a dataset referenced, and otherwise waits for it with no deadline. | For a linear ABD the driver has the zio's own buffer (`abd_borrow_buf()`), so completing a stuck zio early lets a late DMA write freed memory. Doing it safely (bounce buffers, orphan records, a deferred LDI close) belongs with the driver work (see Export and unload). |
| File systems | The export detaches a failed pool's file systems in the kernel (`zfs_fail_mounts()`), and `zpool export` unmounts them afterwards. | Unmounting first races with the mounts and receives that the failure wakes, and an unmount waits without a deadline for the vnode operations in progress. Zones and stacked mounts then don't hold up the export (see File systems). |
| Volumes | The export fails each open volume (`zvol_fail()`), releasing its objset; its minor stays until the last close. | Propolis gets errors instead of hanging, and the export doesn't wait for consumers to close. COMSTAR and dump volumes can't be let go of, so they keep the pool busy (see Volumes). |
| Blocked streams | The export marks a failed pool's sends, receives and diffs cancelled and wakes them with `thread_abort_sleep()`; they fail with `EIO`. | A stream asleep on its descriptor keeps its dataset held and the export at `EBUSY`. A signal would kill `zfs send` or `zfs receive` by default, is lost if ignored or blocked, and disturbs programs that use libzfs in-process (see Send, receive and diff). |
| Command line | `zpool export -F` for any pool, plain `zpool export` for a failed one, rerun after `EBUSY`; no destroy of a failed pool. | sled-agent shells out to zpool, and rerunning after `EBUSY` is enough. Destroying needs labels a dead drive can't take, and expunging a disk only needs the pool gone (see Userland). |
| Reporting | Health FAILED (`ZPOOL_CONFIG_FAILED`, ZFS-8000-LR) and one `io_failure` ereport with `pool_failed`, diagnosed as `fault.fs.zfs.pool_failed`, however the pool failed. | sled-agent needs a state it can act on rather than status text to parse, and fmd gets one ereport per failure rather than one per fenced zio (see Userland, FMA). |

## Known limitations and open issues

Tracker IDs are in parentheses (see the README). "Also on master" means that illumos-gate master, and OpenZFS master where noted, has the same problem without this work.

### Limits of the design

- An I/O that a driver never completes keeps a failed pool from being exported. If the I/O keeps a dataset referenced, the export returns `EBUSY` at its deadline and can be rerun; otherwise the export blocks, uninterruptibly and with no deadline, in the teardown of a file system or volume or in `spa_unload()`, and once it is past its reference check every lookup of the pool blocks with it (see I/O that never completes).
- A send, receive or diff whose thread is stopped (job control or `/proc`) or asleep uninterruptibly isn't woken by `thread_abort_sleep()`, so the export returns `EBUSY` until the process continues or exits.
- A vnode operation on a failed pool's file system that is asleep outside the pool, such as a read faulting in a mapped page of a file on a hung device, keeps the file system attached, so the export returns `EBUSY` until the operation returns.
- A page that `zfs_inactive()` was writing out when the pool failed holds only `z_teardown_inactive_lock`, so the bounded waits before the teardown don't see the dirty data it adds afterwards. If a log write that never finishes holds a txg open, the teardown, of the export's detach or of a forced unmount, then waits for that data without a deadline. A bounded wait for `z_teardown_inactive_lock` in `zfsvfs_failed_log_wait()` would close this, but `forced_export_dirty_pages` would need a new probe for it.
- A death pool fails only where it would otherwise suspend (see Pool state and failure). A disk that returns read or checksum errors but accepts writes leaves the pool ONLINE (as in CS-1241), and an idle pool on a dead disk stays imported until it next does I/O; sled-agent has to export such a pool with `-F`. Repeated probe failures don't suspend a pool on illumos (OpenZFS 939e0237c5 isn't ported; PT2).
- `EIO` from a wait on a failed pool means the change may be lost, not that it was: a pool that fails after a txg's uberblocks reached the disks, but before its odd labels did, imports at that txg.
- User-data reads from a failed pool depend on what is cached, and a cached block can hold writes that are gone once the pool is imported again. Whether such reads should always fail is open.
- The export leaves a failed pool's mountpoint directories behind, since removing one depends on properties the pool can't read. A detached file system that `zpool` can't unmount stays mounted, failing with `EIO`.
- A failed pool with a volume that COMSTAR holds or that is the dump device can't be exported until the consumer lets go; `-F` refuses to fail a pool with such a volume or a swap volume.
- An import of a `wait` or `continue` pool whose first syncs suspend hangs, as upstream, blocking lookups of that pool, or every pool command if it suspends while `spa_import()` holds `spa_namespace_lock`. `zpool export -F` releases it once the import's sync thread is running: the import then fails with `EIO` and leaves no pool, or, if the pool fails after the import can back out, returns `EIO` with the pool imported and failed (see `spa_exit_fail_by_name()` and A pool that fails while it loads). Also on master, illumos and OpenZFS (FE43).
- A `wait` or `continue` pool that suspends in `spa_sync()` just after a scrub finishes can wedge every pool command, `zpool clear` included: `spa_vdev_resilver_done()` queues for `SCL_ALL` as writer behind the suspended sync, and config readers holding `spa_namespace_lock` queue behind it (see Export and unload). `zpool export -F` releases it, and death pools never suspend. Also on master, illumos and OpenZFS (FE19).
- `failmode=death` can't be set on a suspended pool (`ZFS_IOC_POOL_SET_PROPS` returns `EAGAIN`); `zpool export -F` removes such a pool.

### Open bugs that bear on forced exit

- A `mkdir` in `.zfs/snapshot` of a detached file system, by a process already in that directory, panics: `zfsctl_snapdir_mkdir()` reads `z_os` without `ZFS_ENTER()`, and detaching leaves it `NULL`. Also on master, where it races with forced unmount, rollback and receive; the fix is filed upstream (illumos 18755, OpenZFS #19939) and isn't on this branch (AU7).
- A pool that fails during an async destroy can still panic at four sites that don't check for failure, one of them on non-DEBUG kernels (see Syncing context). Testing hasn't hit them; a `spa_failed()` check returning `EIO` at each would close them (FE42).
- A teardown (forced unmount, rollback, `zfs receive -F`, or the detach at export) can deadlock with the removal of a file that has extended attributes: the xattr directory's `zfs_inactive()` takes `z_teardown_inactive_lock` as reader again, behind the waiting writer. Also on master; detaching adds a way in, and `zfsvfs_teardown()`'s brief writer hold before `zil_close()` adds a window (FE49).
- `zfs_setsecattr()` reads `z_log` before `ZFS_ENTER()`, so a setfacl racing an online receive or rollback of a `sync=always` file system can commit on a `NULL` or freed zilog. Also on master; on a detached file system `ZFS_ENTER()` fails first (FE48, PT14).
- DEBUG kernels with `ZFS_DEBUG_ZIO_FREE` can panic with "Deadlock: cycle in blocking chain": `metaslab_check_free()` takes `ms_lock` under `db_mtx`, the sync thread takes a dbuf hash lock under `ms_lock`, and `dbuf_find()` takes `db_mtx` under the hash lock. Seen once in a full ZTS run; also on master, illumos and OpenZFS (FE46).
- FMA can still fault a device of a re-imported pool for errors from before its import, through a case restored by an fmd restart within the 15-second remove window or a late zfs-retire action (FE44). A restored case's remove timer fires at once (FE30), and zfs-diagnosis never matches an inactive spare, whose guid it formats in hex for `zpool_find_vdev()`, which parses decimal (FE28). All also on master.
- `zfs list`, `zfs get` and `zfs receive` dump core when an ioctl returns `ECKSUM`, since illumos libzfs has no `EZFS_CKSUM` (OpenZFS 6c8e9f09c2). A failed pool returns `EIO`, but the branch's fixes that return read errors instead of panicking let a healthy pool's `ECKSUM` reach userland. Also on master (FE45).
- `ZFS_IOC_FSGETXATTR` on a detached file system returns its cached znode flags rather than `EIO`; cosmetic (AU11).

### Testing infrastructure

- ztest's post-pass `zdb -Y` can spin for days on a split block it can't reconstruct, hanging zloop. Also on OpenZFS master (FE10).
- ztest can falsely report "missing log records" after a failed log block, which forced exits make more common. The fix is filed upstream (illumos 18735), not on this branch (IL8).
- A pool imported after a crash in which the head log block reached the disk but its first `WR_INDIRECT` data didn't can later panic ("checksum of cached data doesn't match BP") if a slog is offlined or removed or replay is disabled, a state forced exit leaves more often. Also on illumos master; fixed on another branch (IL19).
- Not ZFS: with fbt probes enabled, as in the chaos harness, a module autounload can panic DTrace (`fbt_invop`; the campaigns set `mod_uninstall_interval`) (FE24), and ztest can abort with "buffer modified after being freed" from a use-after-free in the kernel's `lwp_mutex_wakeup()` system call (illumos 18670, IL27).
- Pre-existing ztest failures: `ENOSPC` in `user_release_one` (IL10) and the `dn_free_txg` assertion through `ztest_remap_blocks` (IL11).
- `forced_export_cold_cache` doesn't require any block to be poisoned; only `forced_export_ereports` and `forced_export_destroy` check that poisoning happens.

### Not settled upstream, and rollout

- The on-disk failmode value 3, ZFS.dict code 19 (`fault.fs.zfs.pool_failed`) and message ID ZFS-8000-LR aren't agreed with illumos or OpenZFS, and the ZFS-8000-LR knowledge article that `zpool status` points to doesn't exist.
- A kernel without this work treats a `failmode=death` pool as `failmode=wait` and names its failmode "panic" in ereports. Inserting `ZPOOL_STATUS_FAILED` renumbers the later `zpool_status_t` values; whether anything outside the gate depends on them hasn't been checked.
- omicron's `ZpoolHealth` parsing rejects unknown values, so it has to accept FAILED before any pool runs `failmode=death` or sled-agent runs `zpool export -F`; reporting it to Nexus needs a new API version and a database enum migration.
- It isn't known whether the drive in CS-1241 failed its writes or hung them. If they hang, the pool doesn't fail by itself, and after `-F` the export returns `EBUSY` or waits on the hung I/O (see I/O that never completes).
- The landing order isn't settled. The plan is stlouis first, then illumos-gate, with the prerequisite fixes going upstream separately; for illumos-gate, the stlouis-only raw-volume hunks would be split out.

### Pre-existing issues independent of forced exit

- A discard through a read-only open of a volume (`DKIOCFREE` on a snapshot volume) can panic. Also on master, illumos and OpenZFS (AU1).
- On a nearly full pool, dropped initialize and TRIM progress sync tasks leave that txg's progress slot stuck; OpenZFS 3808032489 fixes it (FE7).
- A vdev probe holds the config lock, so probing a dying disk stalls other config-lock users; fixed in OpenZFS, not ported (PT7).

### Questions from code reading

These were found by reading the code at the tip; none has been reproduced or tested. Items marked "Bug" are confirmed by the code; the others describe what the code does and ask whether that is what we want.

- Bug: the export of a failed pool can wait for a volume of another pool. Once the pool has failed, `zvol_fail_minors()`, and after a successful export `zvol_remove_minors()`, take `zfsdev_state_lock` with no deadline. A volume's first open, `zvol_create_minor()` and `zvol_set_volsize()` hold that lock while they open and read their pool, so one waiting on a different, suspended pool stalls the export until that pool resumes or is failed. The last close of a COMSTAR or dump volume of the failed pool, which `zvol_fail()` refuses, holds it as well while its `zil_close()` waits for a log write that never finishes (see Closing the log of a failed pool).
- Bug, narrow: `zvol_pinned_minors()` doesn't see a dump volume being set up. It doesn't take `zfsdev_state_lock`, which `DKIOCDUMPINIT` holds while `zvol_dumpify()` prepares the volume, and `zvol_dumpify()` sets `ZVOL_DUMPIFIED` only partway through, so `zpool export -F` during `dumpadm -d` to a volume of the pool can fail the pool rather than return `EBUSY`.
- Bug, narrow and older than forced exit's use of it: `ZVOL_EXTERNAL` can be lost. `zvol_get_volume_params()` sets it in `zv_flags` holding only `zv_state_lock`, while `DKIOCSETWCE` and `zvol_dumpify()` change `zv_flags` holding only `zfsdev_state_lock`, so with a write-protected COMSTAR LU (which another opener can share) a concurrent `DKIOCSETWCE` can overwrite it. `zvol_pinned_minors()` and `zvol_fail()` would then fail the volume under COMSTAR, which keeps using its objset, log and dnode. Every `zv_flags` writer should hold `zv_state_lock`.
- `zio_alloc_zil()` has no `spa_failed()` check, so a commit already past `zil_commit()`'s check, and `zil_failed_wait()` issuing a log's open lwb on every `zil_close()`, unmount, `zfsvfs_detach()` and `zvol_fail()` of a failed pool, allocate real DVAs from the metaslabs (see Allocation). The writes never reach a disk and the allocations are dropped at unload, but loading an unloaded metaslab reads its space map, which fails in the fence, or waits without a deadline for a load in flight, in `zil_failed_wait()`'s case under `zl_issuer_lock`. Should it take the fake-DVA path, or return `ENOSPC` to end the lwb chain?
- `spa_sync_iterate_to_convergence()` checks `spa_failed()` before and after the group of `ddt_sync()`, `dsl_scan_sync()`, `svr_sync()` and `spa_sync_upgrades()` but not between them, and `ddt_sync()` has no check of its own. `dsl_scan_sync()` checks for itself, and the other two do little (removal progress and one MOS ZAP entry; the checksum salt outside upgrades), so a pool that fails in the group risks only an unaudited `VERIFY` on poisoned zeros, as anywhere in syncing context.
- `dsl_deadlist_insert_failed()` and `dsl_scan_iterate_failed()` fail a pool only if its failmode is `death`, whether or not it is armed, so a `wait` or `continue` pool armed at reboot or by ztest still panics there, as on master: `VERIFY0()` on every kernel for the deadlist, `zfs_panic_recover()` for the scan. That matches the rule that arming acts only where a pool would suspend, and these sites never suspend; is it what we want at shutdown?
- `zfs_pool_fail()` checks for pinned volumes even when the pool has already failed, so `zpool export -F` of a failmode=death pool that failed by itself returns `EBUSY` for an open swap volume, while a plain `zpool export` fails the volume and removes the pool. The pin can't save swap, whose I/O fails on a failed pool either way, and only keeps the pool imported; should `-F` skip the check for a pool that has already failed?
- Nothing refuses or warns about `failmode=death` on the root pool (`spa_prop_validate()` only range-checks the value), so a root pool can fail by itself. `-F` refuses the root pool and `-a` skips it, but a plain `zpool export` of an already-failed root pool has no root check, and is stopped only by a busy dump volume, not by a swap volume. Should either be refused?
- `spa_prop_validate()` sets `spa_failmode` in core, and returns `EIO`, for a suspended pool. `ZFS_IOC_POOL_SET_PROPS` reaches that only if the pool suspends after its `POOL_CHECK_SUSPENDED` check, as can `spa_import()`'s setting of properties after the load, and the pool then stays suspended, with `failmode=death` only in core, until its next `zio_suspend()` fails it.
- `spa_export_failed_wait()` waits up to 20 s in `cv_timedwait()`, which a signal can't cut short, as do `zvol_fail()`'s and `zil_failed_wait()`'s bounded waits and the detach's `rrm_enter_write_deadline()`, and at the deadline it logs only the counts of references and injection handlers, not which holders remain. The last close of a volume on a failed pool repeats `zvol_fail()` until its log writes are done, so `close(2)` can wait without bound, uninterruptibly. Should these waits be interruptible, and should the export name the holders?
- `ddt_lookup()`'s tolerance of read errors and `dsl_dataset_hold_obj()`'s error returns apply to every pool, not only failed ones (see Read errors in syncing context). On a healthy pool a DDT read error leaks the block, whose entry keeps the reference that the free should have dropped, where master asserts, and a dataset hold returns errors from `load_zfeature()`, the bookmark-names lookup and the remap deadlist lookup; these could go upstream separately, without `spa_failed()`.
- Fenced flushes succeed, `CANFAIL` or not, so an lwb written before the failure and flushed after it completes without error. That is sound: `zil_commit_impl()` rechecks `spa_failed()` after its wait, a flush can only be fenced after `spa_failed()` became true, and `spa_exit` never goes back, so the recheck sees the failure (see Errors from `zil_commit()`).
- With `sync=disabled`, `zil_commit()` returns 0 before it checks `spa_failed()`, and `zfs_fsync()` doesn't call it at all, so `fsync()`, `O_DSYNC` writes and a volume's `DKIOCFLUSHWRITECACHE` return 0 on a failed pool until the file system is detached or the volume failed. That is consistent with `sync=disabled` on a healthy pool; returning `EIO` would need a check in `zfs_fsync()` as well as in `zil_commit()`.
- `spa_exit_fail_by_name()` leaves an import that hasn't started its sync thread alone, and the export waits for it (see `spa_exit_fail_by_name()`). Since a load whose pool fails is no longer retried (see A pool that fails while it loads), `-F` could fail such an import too, which would then fail with `EIO`, except before `spa_activate()`, which resets `spa_exit`. Should it, rather than wait for an import whose reads may be slow?
- Bug, found in testing rather than by reading: `umount -f` and `zfs unmount -f` of a failed pool's mounted file system fail at once with "cannot open '<dataset>': I/O error", and leave it mounted. `unshare_unmount_path()` opens the dataset by name (`zfs_open()`) before it calls `umount2()`, and on a failed pool that reads blocks that the failed txg dirtied, which are no longer cached; it unmounts by mountpoint only when `stat()` fails, as for a detached file system. Only the export unmounts it. `forced_export_log_writes` calls `umount2()` itself.
- `zpool destroy` of a failed pool says "use 'zpool export -f' to remove it", but a plain `zpool export` removes it; `-f` matters only for a pool with an active shared spare.

## Testing

ZTS tests show each user-visible behavior on a real kernel, one scenario at a time. ztest fails its pool at random points under every ztest operation, which finds the code that has to tolerate a failed pool; zloop runs it for hours beside a baseline without forced exit. The chaos campaign fails a pool at random points under a sled-like workload on a running kernel, reaching what ztest can't: the ZPL, volumes, `vdev_disk`, the ioctls, mounts and unmounts. Everything runs on disposable VMs, on DEBUG builds.

### ZTS

The branch adds 60 tests in a new `failmode/` directory, 12 in `cli_root/zpool_export`, 3 in `cli_root/zpool_import`, and one each in `fault/`, `mmap/`, `removal/` and `zvol/zvol_misc/`; it changes four existing tests and adds the new ioctl to `libzfs_input_check`. All of them are in `common.run`. `forced-exit/tools/forced-exit.run` (147 tests in 14 groups) lists them with the existing tests of the groups whose code the branch changes; its header says how to run it.

`libtest.shlib` gains `pool_is_suspended` and `pool_has_failed`, which read the `spa_t` through mdb, since `zpool status` needs `spa_namespace_lock` and some tests leave it held by a thread asleep on a suspended pool. `failmode/failmode.kshlib` stops a pool by failing every write (`zinject -e io -T write`) and the probe that follows a write error (`zinject -L pad2`). `failmode/forced_export_pinned.kshlib` fails a failmode=death pool at a chosen point: with the pool's I/O slowed (`zinject -D`), a DTrace program makes every write fail when the target function is entered (or, for a log block write, when a txg sync starts while it is in flight; DTrace then holds that sync, the last before the block is done, by spinning (`chill()`) while its thread is on a CPU, until the write faults (`-e io`) are in or 400 ms have passed), and each case is retried until `spa_fail()` runs before the target ends (for some cases, before that txg's `spa_sync()` returns).

Suspension (failmode=wait and continue; most come with the prerequisite fixes):

- `failmode_dmu_tx_wait`, `failmode_dmu_tx_continue`, `failmode_nowait_wait`, `failmode_nowait_continue`: on a suspended pool, `DMU_TX_WAIT` writers and ZPL operations that assign with `DMU_TX_NOWAIT` block without spinning until the pool resumes (wait), or fail at once (continue).
- `failmode_admin_isolation`: a suspended pool doesn't block administration of other pools, and its plain export fails rather than waiting under `spa_namespace_lock`.
- `failmode_status_resilver`: a pool that suspends during a resilver shows as suspended.
- `failmode_zil_flush_error`: a failed flush after a log block write makes `zil_commit()` fall back to the txg.
- `failmode_write_errors_probe_ok` (wait, continue, death): a disk that fails every write but answers probes stops the pool after `zio_reexecute_max` reexecutions.
- `failmode_transient_no_errlog` (wait, continue, death): writes that fail only until the pool stops aren't logged as permanent errors.
- `failmode_fsync_wait`, `_msync_wait`, `_osync_wait`, `_syncalways_wait` (OpenZFS 1f8c39ddb2): the sync blocks while the pool is suspended and succeeds after `zpool clear`.

failmode=death:

- `failmode_death_fails_alone`: a death pool whose writes fail fails without suspending and shows FAILED; `zpool clear`, `zpool online`, `zpool reopen`, `zpool scrub`, `zpool initialize`, `zpool trim` and `zpool destroy` refuse it; I/O and commands on it return; nothing more reaches its disks; `zpool export` removes it, and it imports at its last synced txg.
- `failmode_death_enospc`: `ENOSPC` in syncing context (forced with mdb) fails a death pool rather than suspending it.
- `failmode_death_enospc_reexecute`: with `zio_reexecute_max` at 0, a block whose allocation fails just before MMP fails the pool is written into the fence with a fake DVA, not left as a hole that would read back as zeros.
- `failmode_death_export_f`: `zpool export -f` removes a death pool whose device stopped working; the export's own sync fails it.
- `failmode_death_props`, `failmode_death_cold_metadata`: a failed pool reports properties and features from memory or as unknown, never wrong, and `zfs list` and `.zfs/snapshot` list every snapshot or fail, never stopping early.
- `failmode_death_recoverable_errors`: errors ZFS recovers from (a successful retry, failed cache flushes, read errors in one file) neither fail nor suspend a death pool.
- `failmode_failed_fma`: FMA diagnoses a failed pool as ZFS-8000-LR even when every write and retry failed, and the fault clears at export.
- `failmode_vdev_state_death`: `zpool online`, waiting for its txg, returns when the pool fails.
- `failmode_fsync_death`, `_msync_death`, `_osync_death`, `_syncalways_death`: the sync returns an error, without blocking, when the pool fails.

`zpool export -F`:

- `forced_export_fence`: `-F` fails and exports a suspended pool; its parked I/O never reaches the disk, which works again, and it imports at its last synced txg with a clean `zdb -bcc`; when one of two disks fails, neither gets writes.
- `forced_export_healthy`: `-F` of a healthy pool keeps what had synced and the synchronous writes the ZIL replays, and loses the rest.
- `forced_export_slow`: `-F` of a slow failmode=wait pool fails it at once rather than waiting for it to sync.
- `forced_export_idle`, `forced_export_idle_lofi`, `forced_export_read_errors_only`: `-F` finishes for an idle pool whose device stopped working (injected errors, or its lofi device removed) and for a pool whose reads fail.
- `export_suspended_eagain`: a plain or `-f` export of a suspended pool fails at once, pointing to `-F`, and the pool can still resume.
- `forced_export_retry`: a `-F` that returns `EBUSY` because a zinject handler holds the pool leaves it failed, and a rerun without the handler exports it.
- `forced_export_namespace_sleeper`: `-F` works while `zpool reguid` sleeps on the suspended pool holding `spa_namespace_lock`, and the reguid returns.
- `forced_export_zvol_first_open`: `-F` of a suspended pool finishes while a volume's first open waits for the pool holding `zfsdev_state_lock`, and the open returns; `-F` of a pool with a swap volume still returns `EBUSY` and leaves the pool as it was.
- `forced_export_failed_swap`: once a failed pool with a swap volume has been exported, `-F` of a new pool of the same name isn't refused for the failed volume, and swap can then remove it, after which the volume goes away.
- `forced_export_import` (death, and wait failed by `-F`): an import whose pool fails because its first txg can't be written fails with `EIO` and leaves no pool, and the pool imports later as it was. The pool is on a file in another pool, exported frozen with log blocks to claim, so that the import waits for its first txg; the outer pool's slog is slowed with `zinject -D`, so that the txg's first flush (an `fsync()` of the file) waits, and the outer pool is failed then, which fails every later write to the file. Writes can't fail from the start, since opening the pool probes each leaf with a write.
- `forced_export_other_pools`: commands on another pool, including its export and import, and opens of its volumes finish within 5 s while one pool is suspended and while `-F` fails it.
- `forced_export_busy_fs`, `forced_export_zvol` (each also `_continue` and `_death`): `-F` finishes with writers in `fsync()`, `O_DSYNC` writes and `msync()` and other holders in the file system, or with an open regular and raw volume being written; no sync that returns after the export started succeeds.
- `forced_export_detach`: busy, nested, snapshot and stacked mounts are detached at export, fail with `EIO`, and are unmounted once the pool is gone, even while processes keep looking up paths in them.
- `forced_export_mount_races`: `-F` finishes when it races a mount in log replay, or an online receive whose resume fails, and leaves nothing mounted.
- `forced_export_stuck_vop`: a read on a failed pool's file system, asleep faulting in a mapped page of a file on another, slow pool, makes the export return `EBUSY` at its deadline without making other operations on the file system wait, and the export succeeds once the read is done.
- `forced_export_blocked_streams`: `-F` frees a send, a receive and a diff blocked on their pipes without signaling them; a send whose own process is stopped keeps the export at `EBUSY`.
- `forced_export_cold_cache` (death, and wait failed by `-F`): a pool that fails with nothing cached while it syncs large frees, truncates and overwrites drains without panicking or hanging; the test logs how many blocks were poisoned but doesn't require any.
- `forced_export_ereports`: a failed pool posts one ereport (`io_failure`) and none for fenced reads, their retries or late device completions; the fenced reads are poisoned and their readers get `EIO`.
- `zpool_export_hardforce_001_pos` through `_006_pos`, `_send_001_pos`, `_send_002_pos`, `_receive_001_pos`, `_receive_002_pos` (adapted from openzfs#11082): `-F` of healthy, unmounted, nested-mount and suspended pools, including one with a plain export already running on it and one with `zpool reguid` asleep holding `spa_namespace_lock`; sends and receives get `EIO`, and the export is rerun after `EBUSY`, as sled-agent does. The send and receive tests need `/usr/bin/pv`.

Failure at a chosen point (failmode=death; `forced_export_destroy`, `forced_export_dirty_pages`, `forced_export_log_writes` and `forced_export_log_removal` have their own DTrace, and the others go through `forced_export_pinned.kshlib`):

- `forced_export_pinned_sync`: writes start failing as the sync enters `dsl_pool_sync()` (the first and a later pass), `dsl_pool_sync_mos()`, `dsl_free()`, `metaslab_sync()`, `spa_flush_metaslabs()` or the label writes, and the pool fails inside the first two, or for the others before that txg's `spa_sync()` returns; each time it exports, imports with every write whose `fsync()` returned 0, and scrubs clean.
- `forced_export_pinned_zil`: the same in `zil_commit()`, with a log block write, its flush or a `dmu_sync()` write in flight, and during `zil_replay()`.
- `forced_export_log_writes`: with a log block write delayed past the failure (MMP fails the pool, since the txg sync waits for the log block), a rollback fails at once with `EIO`, and a forced unmount and the export return errors at their deadlines (the test calls `lzc_rollback_to()` and `umount2()` itself, since `zfs rollback` and `umount -f` can't open the dataset on a failed pool); once the write is done, the pool exports and imports with every write whose `fsync()` returned 0.
- `forced_export_send`, `forced_export_recv`: a send or receive whose pool fails mid-stream, or in the txg of `dmu_recv_begin_sync()` or `dmu_recv_end_sync()`, fails and the pool exports (a send with a stopped reader is woken, not killed); after import the receive resumes or is redone and matches its source.
- `forced_export_removal`: the pool fails during a device removal's copy, and as it completes; the removal finishes after import.
- `forced_export_log_removal`: the pool fails as a log device's removal frees its metaslabs, after the removal's last check; the removal fails with `EIO`, and the device is still in the pool after import and can then be removed.
- `forced_export_destroy`: a clone destroy in syncing context gets past the blocks it can't read and fails; the clone is there after import.
- `forced_export_dirty_pages`: a forced unmount (which keeps the pages), or `-F` of a death pool, tears a file system down while `zfs_inactive()` writes the dirty pages of a just-unmapped file.

Other tests:

- `fault/zfs_create_prop_error`: `zfs create` fails rather than panics when it can't read its parent's normalization, utf8only and casesensitivity properties.
- `fault/flush_error` (changed): a flush the device doesn't support (`ENOTTY`, `ENOTSUP`) succeeds.
- `mmap/mmap_unwritable_pages`: unwritable dirty pages (`EDQUOT`) of a closed, unmapped file are discarded, so the file system unmounts.
- `removal/removal_with_resilver` (OpenZFS 47d5d5fc26): a mirror can't be removed while a child needs resilvering.
- `zvol/zvol_misc/zvol_last_close_stall`: a zvol's last close with dirty data doesn't stall opens of other zvols.
- `zpool_import_parallel_pos`, `_neg`, `_admin`, `zpool_export_parallel_pos`, `_admin` (parallel import and export ports): imports and exports run in parallel, same-name imports have one winner, an import doesn't block admin commands to other pools, and admin commands can't race an export of their pool.
- `mmp/mmp_inactive_import`, `mmp/mmp_reset_interval` (changed): use `export_pool_skip_update` instead of `zpool export -F`, which here fails the pool.
- `cli_root/zdb/zdb_001_neg` (changed): `-Y` is valid since the port of OpenZFS 64bdf63f5c and 13d454c6ca.

Left out, because they need changes the branch doesn't have: OpenZFS's `_continue` sync tests (the rest of its ZIL "crash" series), `failmode_vdev_state` (OpenZFS b098c60ee6's `spa_vdev_state_exit()` change), `failmode_health` (the userland part of OpenZFS f0ed6c7448), and a death version of `fault/suspend_on_probe_errors` (OpenZFS 939e0237c5).

### ztest

`ztest_force_exit()` runs about once a minute, like `ztest_reguid()`, and fails the pool one of three ways: failmode=death with every write failing; failmode=wait, armed (`spa_exit_arm()`), with every write failing, so that the pool fails when it suspends; or `spa_fail()` on the healthy pool, as `zpool export -F` does. Half the time it flushes the ARC first, so that syncing context finds nothing cached. The write errors come from two zinject handlers with no vdev guid, which cover every leaf at once: a write fault, and a label fault on `vl_be` so that the probe after a write error fails as on a dead disk.

With probability `-X` (default 50%) the other test threads keep running, so the pool fails in the middle of ZIL commits, `dmu_sync()`, writes, and object, dataset and vdev changes. Each test must then give up, using `ztest_failed()` to tell the pool's failure from an error of its own, and park; ztest aborts if the threads haven't parked within 300 s. Otherwise the threads park first, and the pool fails while it syncs what they left dirty.

ztest then clears the handlers, exports the pool with `spa_export()` (hardforce), imports it, and checks that:

- the pool isn't failed and, if the threads were parked, has the same guid;
- the txg on disk (`spa_first_txg() - 1`) is between the last txg that changed the pool (the birth of `spa_ubsync`'s root block pointer) and `spa_last_synced_txg() + 1` at the failure, the extra txg being one whose uberblocks reached the disks before the pool failed while committing it;
- reopening the datasets claims and replays the ZIL, when it has records, at least up to the last record that a `zil_commit()` acknowledged before the failure (`zd_seq`), or ztest aborts with "missing log records".

The parent's usual `zdb -bcc` after each pass finds leaked space and bad checksums. `ztest -x` leaves forced exit out, and so do MMP runs (`-M`).

### zloop

The long run is a pair of 12-hour zloops on one VM, each on its own disk, driven by `forced-exit/tools/zlr.sh`, which restarts zloop if it exits early: one with ztest's defaults, so forced exit is on (`-X 50`), and one that passes `-x` to ztest. The `-x` run is the baseline: a crash it also has is not forced exit's.

### Chaos campaign

The chaos harness (`forced-exit/chaos/`; `forced-exit/chaos/README.md` describes it) fails a pool at a random moment under a mixed workload on a running kernel, exports it with the workload attached, imports it and checks the result, over and over. Each iteration draws from a logged seed the pool's shape (file vdevs, or lofi devices through `vdev_disk`), its failmode (mostly death), the trigger (writes failing before they reach the device with `zinject -e io-prefail`, which the branch takes in part from OpenZFS 6562851406; all I/O failing; the lofi devices removed; or `-F` of the busy, healthy pool) and the export flags. The workload has `fsync()` and `O_DSYNC` writers to files and a raw volume, streams, snapshots, a scrub, the commands sled-agent polls, processes holding files and mappings in the pool, and optional Oxide-like activities (Crucible, key rotation, zone teardown and others). Each iteration checks that no I/O reaches a leaf after the failure (DTrace), no write started after the failure is acknowledged, the export finishes within 60 s with the holders attached, the uberblock on disk is `spa_ubsync`'s txg or the next, no two log blocks to be claimed share a DVA, and after import every acknowledged write is there and a scrub and `zdb -bcc` are clean. A watchdog treats a pool command blocked for 30 s as a wedge and runs `zpool export -F`, which must release it; only a wait or continue pool may wedge.

### Builds

Every commit builds on its own: an incremental DEBUG build of illumos with packages (helios-build `build-illumos -d -i`), with no build errors, warnings or package errors, so each commit's package manifests also match its proto area.

### Results

The full ZTS run, `forced-exit.run` and zloop ran on a build whose kernel and userland code is the tip's apart from two lines that the tip rewraps for cstyle (a comment in `spa_exit.c` and ztest's usage message); tests changed since that build ran at their tip versions. The chaos campaigns and the repeated runs of `forced_export_ereports` and `forced_export_destroy` ran on an earlier build, through commit 80 (see the README), without the fixes in 81-91.

- Full ZTS: `common.run` without the `l2arc` group (1,422 tests, counting setups and cleanups): 1,408 pass, 7 fail and 7 are skipped. Five of the failures also fail on illumos master (`enospc_002_pos`, `projectspace_004_pos`, `refreserv_multi_raidz`, `send_encrypted_freeobjects` and `slog_014_pos`), `slog_lwb_write_error` fails on the mount point that `slog_014_pos` leaves behind, and `scrub_after_replace` fails because of commit 29 (below). The skipped tests (four in `mmp`, two in `inuse`, and `rsend_008_pos`) report themselves unsupported.
- `forced-exit.run` (147 tests in 14 groups, and 25 setups and cleanups): 171 pass, and `mmp_reset_interval` is skipped, since it reports itself unsupported on illumos.
- Two flaky tests were fixed. `forced_export_pinned_zil`'s `lwb_in_flight` case often missed its target, because zinject, which DTrace's `system()` starts, ran only after the txg sync that could fail the pool had finished; DTrace now holds that sync until the faults are in, and the case then failed the pool inside its target on the first try in 20 of 20 runs of a reproducer. `failmode_death_enospc_reexecute` hit its case in about 37% of tries and failed when all 5 missed; its MMP window is now shorter and its hold longer, it hit in 24 of 33 tries over 24 runs, all of which passed, and it has 10 tries.
- `forced_export_ereports` passes 20 of 20 in a row, and `forced_export_destroy` 5 of 5.
- zloop: an 8-hour pair on the tip's code completed 327 runs with forced exit and 328 with `-x`, with no crashes on either side. An earlier 12-hour pair, on the build through commit 80, completed 482 runs on each side with no crashes.
- Chaos: 2,342 iterations in three campaigns, with no failures. Three iterations, two on failmode=wait pools and one on a failmode=continue pool, hit the upstream `SCL_ALL`-writer wedge described under Export and unload (FE19), which the watchdog's `zpool export -F` released.
- Builds: every commit builds, as of its last change, and so does the tip.

Known failures and flakes:

- `failmode_failed_fma` and `forced_export_ereports` report themselves unsupported if fmd isn't online, and `failmode_failed_fma` can fail if fmd is backlogged, as after a chaos campaign.
- `slog_014_pos` sometimes times out waiting for its pool to degrade, on illumos master too, and `slog_lwb_write_error` then fails on the mount point it leaves behind. It always fails on a VM where fmd keeps many old cases, as after a chaos campaign. Each new diagnosis checks every case fmd keeps (`fmd_case_convict()`), and each check looks the pool up again through libzfs. Every failed pool leaves a `fault.fs.zfs.pool_failed` case, which fmd keeps for `rsrc.age` (30 days). With the 1,300 pool faults that chaos campaigns left on one VM, each diagnosis took about 35 s, past the test's 30 s wait for its checksum fault, and `slog_lwb_write_error` then failed on the pool that `slog_014_pos` left behind. On such a VM, reset fmd's state before running ZTS: stop fmd, move `/var/fm/fmd/*` aside, recreate `ckpt`, `rsrc` and `xprt` there, and start fmd again.
- `replacement/scrub_after_replace`, which the base gained with illumos 18683, fails because of commit 29. The test starts a scrub, replaces a disk in the txg in which the scrub is set up, and checks that the scrub ran instead of the replace's resilver. Commit 29 clamps a scrub's `scn_max_txg` to that txg, so the scrub doesn't cover the new disk's DTL, and the full resilver runs after it. The test's data checks would pass, but the scrub no longer stands in for the resilver, so the test doesn't reach the case that 18683 fixes. OL17, the fix for upstream that would replace commit 29, has the same effect, so the test needs reworking there (see the README).
- `enospc_002_pos` failed in both of the last two full runs, and fails on illumos master too: its first `zfs snapshot`, just after `enospc_001_pos` has filled the pool and removed its files, returns `ENOSPC`. It passed 6 of 6 reruns of the `no_space` group.
- `projectspace_004_pos`, `refreserv_multi_raidz` (which needs more disks than these VMs have) and `send_encrypted_freeobjects` fail on illumos master too.
- `redundancy_002` and `redundancy_003` are a pre-existing flake (4 of 20 runs fail on stock stlouis).
- The `l2arc` tests hang on these VMs and are killed after 30 minutes; leave them out of full runs.

### Not covered

- Reboot with a suspended or failed pool (`spa_shutdown_callb()`) has no automated test.
- Nothing above ran on a non-DEBUG build.
- No test restarts initialize or TRIM on a failed pool (commit 89): that needs a leaf vdev's ZAP evicted from the dbuf cache and the ARC.
- No test reaches `zfs_suspend_fs()`'s `EIO` on a failed pool (commit 86). A rollback, receive or upgrade started after the failure fails earlier, when it looks up the file system by name (`dsl_dir_hold()`), which reads blocks that the failed txg dirtied and that are no longer cached; reaching the check needs a lookup that started before the failure.
- No test fails a pool while zfs-retire attaches a hot spare or the async thread probes a device; `failmode_death_fails_alone` checks only that `zpool online`, `reopen`, `scrub`, `initialize` and `trim` refuse a failed pool (commit 91). No test reaches the export's second-round deadline, the commit fallback's `TXG_WAIT_FAILED` or `zil_failed_wait()`'s deadline for `zl_issuer_lock` (commit 86), or a detach that waits for a rollback suspending the file system (commit 87).
- No test reaches the cases under Questions from code reading, such as the export of a failed pool waiting for `zfsdev_state_lock` behind a volume's first open on another, suspended pool.
- Real device failures (NVMe errors, PCIe link loss) are approximated only by injected errors and removed lofi devices, and nothing tests sled-agent driving the export.

