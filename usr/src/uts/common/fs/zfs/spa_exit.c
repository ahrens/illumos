/*
 * This file and its contents are supplied under the terms of the
 * Common Development and Distribution License ("CDDL"), version 1.0.
 * You may only use this file in accordance with the terms of version
 * 1.0 of the CDDL.
 *
 * A full copy of the text of the CDDL should have accompanied this
 * source.  A copy of the CDDL is also available via the Internet at
 * http://www.illumos.org/license/CDDL.
 */

/*
 * Copyright 2026 Oxide Computer Company
 */

/*
 * Forced Exit
 *
 * A suspended pool waits for its devices to come back, and every thread that
 * touches it waits with it.  When the devices are gone for good, that is
 * forever.  Forced exit is the alternative: the pool "fails", drops whatever
 * it had not yet written, and is exported, leaving its disks as they were at
 * the last committed txg.
 *
 * States
 *
 * spa_exit moves only forward, under spa_suspend_lock:
 *
 *	SPA_EXIT_NONE	The pool behaves as usual.
 *	SPA_EXIT_ARMED	The pool fails as soon as it is, or becomes,
 *			suspended (spa_exit_arm()).  An armed pool that
 *			never suspends behaves as usual.
 *	SPA_EXIT_FAILED	The pool has failed (spa_fail(), spa_failed()).
 *
 * A failmode=death pool fails wherever it would otherwise suspend
 * (zio_suspend()), whatever the reason: a pool that runs out of space in
 * syncing context can't free any while it is suspended, since that takes a txg.
 * A pool on another failmode fails when it is armed and suspends; unlike the
 * failmode, arming can't be undone, and lasts until the pool is exported.
 * Either one fails a pool that is already suspended.  "zpool export -F" arms
 * the pool, through ZFS_IOC_POOL_FORCE_EXIT (spa_exit_arm_by_name()) before it
 * unmounts anything, and again in spa_export_common().  So does a reboot
 * (spa_shutdown_callb()), so that a suspended pool's unmounts don't hang it.
 * The arming ioctl finds the pool without spa_namespace_lock, which a thread
 * waiting on the pool may hold for good; spa_exit_hold() keeps the pool loaded
 * until it is armed.
 *
 * The fence
 *
 * No I/O reaches a leaf vdev of a failed pool (zio_vdev_io_fence()).  Reads
 * and CANFAIL writes get EIO.  Other writes, flushes and TRIMs succeed
 * without doing anything, and allocations get fake DVAs
 * (zio_dva_allocate_fake()), so that the code that issued them goes on
 * along its usual success path.  Frees and claims are no-ops.  I/O that was
 * parked while the pool was suspended is reexecuted into the fence, and I/O
 * that was already queued below it completes there.  Nothing reports errors,
 * updates vdev stats or reexecutes on a failed pool (zio_done()):
 * spa_fail() posted one ereport for the pool.
 *
 * Draining
 *
 * The sync thread keeps syncing txgs, but into the void: it syncs the dirty
 * datasets (dsl_pool_sync()), which releases the holds that dirty data has on
 * dbufs, dnodes and datasets, and discards everything else
 * (spa_sync_discard(), vdev_sync_discard()).  The phases that would only
 * update on-disk metadata are skipped, and the pool can fail at any point in
 * a pass, so spa_sync_iterate_to_convergence() checks between phases.  No
 * uberblock is written, so spa_last_synced_txg() stops at the last txg that
 * was committed.
 *
 * Every read fails, but syncing context can't cope with errors.  A block it
 * needs that isn't cached is "poisoned" instead (dbuf_poison()): its read
 * fails in the fence, and dbuf_read_done() gives it zeros and sets
 * db_poisoned.  The read doesn't fail the caller's zio, so callers that read
 * several blocks at once get them all.  Nothing that is written reaches the
 * disks, and only syncing context sees poisoned blocks: in open context, a
 * read of a poisoned block, or of any block that isn't cached, fails with
 * EIO.  The zfs:0:forced_exit:poisoned_reads kstat counts the poisoned
 * blocks.
 *
 * Waiting
 *
 * Nothing waits for a failed pool.  spa_fail() wakes every waiter
 * (txg_exit_wakeup(), dsl_pool_exit_wakeup()).  txg waits that asked to be
 * told about suspension, and waits for txgs that were drained rather than
 * committed, return EIO (txg_wait_synced_flags()).  dmu_tx_assign() fails
 * new changes with EIO; callers that pass DMU_TX_SUSPEND still get a txg.
 * zil_commit(), sync tasks (dsl_sync_task()) and vdev changes
 * (spa_vdev_exit()) whose txg was not committed return EIO.  Commit callbacks
 * get ECANCELED.  A failed pool can't be resumed ("zpool clear") or destroyed.
 *
 * Export
 *
 * A failed pool can only be exported.  The export skips the labels and the
 * final txgs, and waits for the holds that woken threads still have to go
 * away (spa_export_failed_wait()) before it marks the pool as being exported,
 * since spa_lookup(), and every command that looks a pool up, waits for that.
 * Open volumes would keep the pool busy, so zfs_ioc_pool_export() fails them
 * first (zvol_fail_minors()): their I/O fails with EIO, their opens with
 * ENXIO, and their minors go away at the last close.  The intent logs are
 * closed without committing anything (zil_failed_close()).  spa_unload()
 * waits for the arming threads (spa_exit_unload_wait()), and spa_activate()
 * starts the next import of the pool in SPA_EXIT_NONE.
 */

#include <sys/zfs_context.h>
#include <sys/spa_impl.h>
#include <sys/zio.h>
#include <sys/txg.h>
#include <sys/dsl_pool.h>
#include <sys/fm/fs/zfs.h>
#ifdef _KERNEL
#include <sys/callb.h>
#endif

static kcondvar_t spa_exit_hold_cv;

/*
 * Has the pool failed?  Once this returns B_TRUE it always will, until the
 * pool is exported.
 */
boolean_t
spa_failed(spa_t *spa)
{
	return (spa->spa_exit == SPA_EXIT_FAILED);
}

/*
 * Fail the pool ("exit start").  From now on no I/O reaches its devices (see
 * zio_vdev_io_start()), so the disks stay at the last synced txg, and every
 * wait on the pool returns rather than blocking.  The sync thread drains the
 * remaining dirty data into the void, and the pool waits to be exported.
 * Called when a failmode=death pool would otherwise suspend, and when an
 * armed pool suspends.
 */
void
spa_fail(spa_t *spa)
{
	zio_t *pio;

	mutex_enter(&spa->spa_suspend_lock);
	if (spa->spa_exit == SPA_EXIT_FAILED) {
		mutex_exit(&spa->spa_suspend_lock);
		return;
	}
	spa->spa_exit = SPA_EXIT_FAILED;

	/*
	 * A failed pool is not suspended: nothing waits for it to resume.
	 * Any I/O that was parked while it was suspended is reexecuted below,
	 * into the fence.
	 */
	spa->spa_suspended = ZIO_SUSPEND_NONE;
	pio = spa->spa_suspend_zio_root;
	spa->spa_suspend_zio_root = NULL;
	cv_broadcast(&spa->spa_suspend_cv);
	mutex_exit(&spa->spa_suspend_lock);

	cmn_err(CE_WARN, "Pool '%s' has failed; unsynced changes will be "
	    "discarded.  Export the pool to remove it.", spa_name(spa));
	(void) zfs_ereport_post(FM_EREPORT_ZFS_IO_FAILURE, spa, NULL,
	    NULL, NULL, 0, 0);

	if (spa->spa_dsl_pool != NULL) {
		txg_exit_wakeup(spa->spa_dsl_pool);
		dsl_pool_exit_wakeup(spa->spa_dsl_pool);
	}

	if (pio != NULL)
		zio_exit_reexecute(pio);
}

/*
 * Arm the pool for forced exit: it fails as soon as it is (or becomes)
 * suspended.  An armed pool that never suspends behaves normally.
 */
void
spa_exit_arm(spa_t *spa)
{
	mutex_enter(&spa->spa_suspend_lock);
	if (spa->spa_exit == SPA_EXIT_NONE)
		spa->spa_exit = SPA_EXIT_ARMED;
	mutex_exit(&spa->spa_suspend_lock);

	spa_exit_check(spa);
}

/*
 * Hold a pool found in spa_namespace_avl without spa_namespace_lock, so that
 * it can be armed (see spa_exit_arm()) once spa_namespace_avl_lock is
 * dropped: arming a suspended pool fails it, which posts an ereport and
 * dispatches I/O, too much to do under a leaf lock.  The hold keeps the pool
 * from being unloaded (see spa_exit_unload_wait()), and so from being removed
 * and freed.  Returns B_FALSE if there is nothing to arm: the pool isn't
 * loaded, is being unloaded, or is read-only, and can't suspend.
 */
static boolean_t
spa_exit_hold(spa_t *spa)
{
	ASSERT(MUTEX_HELD(&spa_namespace_avl_lock));

	if (spa->spa_dsl_pool == NULL || spa->spa_exit_unloading ||
	    !spa_writeable(spa))
		return (B_FALSE);
	spa->spa_exit_holds++;
	return (B_TRUE);
}

static void
spa_exit_rele(spa_t *spa)
{
	ASSERT(MUTEX_HELD(&spa_namespace_avl_lock));
	ASSERT3U(spa->spa_exit_holds, >, 0);

	if (--spa->spa_exit_holds == 0)
		cv_broadcast(&spa_exit_hold_cv);
}

/*
 * Called by spa_unload() before it closes the DSL pool: wait for the threads
 * arming the pool to let go of it, and keep new ones away until the pool is
 * activated again.
 */
void
spa_exit_unload_wait(spa_t *spa)
{
	mutex_enter(&spa_namespace_avl_lock);
	spa->spa_exit_unloading = B_TRUE;
	while (spa->spa_exit_holds != 0)
		cv_wait(&spa_exit_hold_cv, &spa_namespace_avl_lock);
	mutex_exit(&spa_namespace_avl_lock);
}

/*
 * Arm the named pool for forced exit (see spa_exit_arm()) without taking
 * spa_namespace_lock, which may be held indefinitely by a thread sleeping on
 * that very pool.  spa_namespace_avl_lock keeps the tree intact while we look,
 * and spa_exit_hold() keeps the pool while we arm it.  Unlike spa_lookup(),
 * this does not wait for an import or export in progress.  A pool that has
 * nothing to arm (see spa_exit_hold()) is exported as usual, so that isn't an
 * error.
 */
int
spa_exit_arm_by_name(const char *name)
{
	size_t len = strcspn(name, "/@#");
	int error = SET_ERROR(ENOENT);
	spa_t *spa;

	/* A spa_t is too big for the stack, so walk the tree. */
	mutex_enter(&spa_namespace_avl_lock);
	for (spa = avl_first(&spa_namespace_avl); spa != NULL;
	    spa = AVL_NEXT(&spa_namespace_avl, spa)) {
		if (strncmp(spa->spa_name, name, len) == 0 &&
		    spa->spa_name[len] == '\0')
			break;
	}
	if (spa != NULL) {
		error = 0;
		if (!spa_exit_hold(spa))
			spa = NULL;
	}
	mutex_exit(&spa_namespace_avl_lock);

	if (spa != NULL) {
		spa_exit_arm(spa);
		mutex_enter(&spa_namespace_avl_lock);
		spa_exit_rele(spa);
		mutex_exit(&spa_namespace_avl_lock);
	}

	return (error);
}

void
spa_exit_check(spa_t *spa)
{
	boolean_t fail;

	mutex_enter(&spa->spa_suspend_lock);
	fail = (spa->spa_exit == SPA_EXIT_ARMED && spa_suspended(spa));
	mutex_exit(&spa->spa_suspend_lock);

	if (fail)
		spa_fail(spa);
}

/*
 * Syncing context on a failed pool drains the dirty data that is left (see
 * spa_sync_iterate_to_convergence()).  Every read it issues fails (see
 * zio_vdev_io_fence()), and "poisoned_reads" counts the blocks that got
 * zero-filled instead (see dbuf_poison()), each of which is also logged with
 * zfs_dbgmsg.
 */
typedef struct spa_exit_stats {
	kstat_named_t	ses_poisoned_reads;
} spa_exit_stats_t;

static spa_exit_stats_t spa_exit_stats = {
	{ "poisoned_reads",	KSTAT_DATA_UINT64 },
};

static kstat_t *spa_exit_ksp;

static void
spa_exit_stat_init(void)
{
	spa_exit_ksp = kstat_create("zfs", 0, "forced_exit", "misc",
	    KSTAT_TYPE_NAMED,
	    sizeof (spa_exit_stats) / sizeof (kstat_named_t),
	    KSTAT_FLAG_VIRTUAL);
	if (spa_exit_ksp != NULL) {
		spa_exit_ksp->ks_data = &spa_exit_stats;
		kstat_install(spa_exit_ksp);
	}
}

static void
spa_exit_stat_fini(void)
{
	if (spa_exit_ksp != NULL) {
		kstat_delete(spa_exit_ksp);
		spa_exit_ksp = NULL;
	}
}

/*
 * Called for every block of a failed pool that got zero-filled instead of
 * read.
 */
void
spa_exit_poisoned_read(spa_t *spa, const struct zbookmark_phys *zb)
{
	atomic_inc_64(&spa_exit_stats.ses_poisoned_reads.value.ui64);
	zfs_dbgmsg("pool '%s' has failed: poisoned read "
	    "<%llu, %llu, %lld, %llu>",
	    spa_name(spa), (u_longlong_t)zb->zb_objset,
	    (u_longlong_t)zb->zb_object, (longlong_t)zb->zb_level,
	    (u_longlong_t)zb->zb_blkid);
}

void
spa_exit_init(void)
{
	cv_init(&spa_exit_hold_cv, NULL, CV_DEFAULT, NULL);
	spa_exit_stat_init();
}

void
spa_exit_fini(void)
{
	spa_exit_stat_fini();
	cv_destroy(&spa_exit_hold_cv);
}
