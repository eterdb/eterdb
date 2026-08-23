/*
 * eter_ssi, EterDB Phase 2 (strict mode): persist Postgres's native SSI
 * predicate-read dependency graph, off the synchronous commit path.
 *
 * What it does
 * ------------
 * Postgres computes a read/write dependency graph inside its SERIALIZABLE
 * isolation machinery (SSI), predicate (SIREAD) locks recording what each
 * transaction read, then discards it at commit. We retain it.
 *
 * At XACT_EVENT_PRE_COMMIT, for a SERIALIZABLE read-write transaction, we read
 * the committing backend's predicate locks via the exported
 * GetPredicateLockStatusData() and append them to a per-database append-only
 * "SSI-WAL" file (DataDir/eter_ssi.<dboid>.wal), tagging each with the read
 * row's primary key (resolved eagerly at read time from a stashed tuple copy,
 * see eter_resolve_pk_from_tuple below, so it survives vacuum). The commit is
 * NOT made to wait on any metadata write. A separate drain step
 * (eter.drain_ssi_wal(), the C function below) ingests the WAL into
 * eter.ssi_reads; SQL then matches those reads to writes by (table, primary
 * key) to produce read-dependency edges (matching by PK rather than ctid lets
 * edges resolve in sidecar mode, where logical-decoding writes have no ctid).
 *
 * Modes
 * -----
 * - Strict mode: native SSI predicate locks exist at SERIALIZABLE.
 * - Observe mode: the EterDB-patched engine (eter_observe_mode) acquires
 *   the same SIREAD locks under READ COMMITTED, so capture works there too.
 * - Read-only transactions have no assigned xid and are skipped, they can never
 *   be an undo target nor constrain a reversal (matches the pitch's exemption).
 *
 * Draining
 * --------
 * The append-only SSI-WAL is per-database (eter_ssi.<dboid>.wal). It is
 * drained either explicitly (eter.refresh_dependencies()) or, when the
 * library is in shared_preload_libraries, automatically by a background worker
 * (eter_ssi.drain_database / eter_ssi.drain_interval_ms). A shared-memory
 * ring buffer (vs. the file) remains a later optimization.
 */
#include "postgres.h"

#include "access/genam.h"
#include "access/heapam.h"
#include "access/parallel.h"		/* IsParallelWorker */
#include "access/htup_details.h"
#include "access/relation.h"
#include "access/xact.h"
#include "access/transam.h"
#include "catalog/index.h"			/* IndexGetRelation */
#include "catalog/pg_type.h"			/* INT8ARRAYOID, INT4ARRAYOID, TEXTARRAYOID */
#include "executor/spi.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "optimizer/cost.h"			/* max_parallel_workers_per_gather */
#include "optimizer/planner.h"		/* planner_hook, standard_planner */
#include "pgstat.h"
#include "postmaster/bgworker.h"
#include "postmaster/interrupt.h"
#include "storage/bufmgr.h"
#include "storage/fd.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/lock.h"
#include "storage/predicate.h"		/* patched engine exports eter_observe_mode */
#include "storage/predicate_internals.h"
#include "storage/proc.h"
#include "tcop/tcopprot.h"			/* die() */
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/hsearch.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/relcache.h"
#include "utils/snapmgr.h"

PG_MODULE_MAGIC;

#ifdef ETER_STRICT_ONLY
/*
 * Strict-mode-only build against STOCK Postgres: observe mode is provided by the
 * core patch (which exports eter_observe_mode from storage/predicate.h). When
 * that patch is absent, build with -DETER_STRICT_ONLY and capture works at
 * SERIALIZABLE only. (test/ssi.sh strict mode; observe mode needs the patch.)
 */
static const bool eter_observe_mode = false;
#endif

void _PG_init(void);
PGDLLEXPORT void eter_ssi_worker_main(Datum main_arg);

/* GUCs (background-worker drain) */
static char *eter_drain_database = NULL;
static int	eter_drain_interval_ms = 1000;

/*
 * Max rows per relation a single transaction's SEQUENTIAL scan captures
 * per-tuple (observe-precision lever 3). Below this, every row a seqscan returns
 * is stashed and the read is captured precisely, and the coarse relation-level
 * read line is SUPPRESSED at commit (so undo of one of those rows only implicates
 * the readers that actually read it, the over-approximation reach
 * shrinks). Above it, the relation is marked "overflowed", we stop stashing its
 * rows and fall back to the sound table-level over-approximation (the pre-lever
 * behavior), which bounds the per-transaction read-set memory regardless of
 * scan size.
 *
 * DEFAULT 0 = OFF (always coarse, suppression never happens). Suppressing the
 * coarse relation line removes the over-approximation that, today, MASKS the
 * irreducible read→PRE_COMMIT residual (a concurrent reader's row that escapes
 * per-tuple capture); turning it on therefore trades a bounded slice of read-edge
 * recall (within the false-clean gate's threshold, but no longer the 0-miss bar)
 * for precision. EterDB's cardinal rule is "never a false clean," so the
 * mechanism ships built + validated but OFF by default; a deployment that values
 * a tighter dependent set over that last fraction of recall opts in by raising
 * this (e.g. SET eter_ssi.max_seqscan_capture = 10000). Flipping the default on
 * is gated on closing the residual (see PLAN observe-precision lever 3).
 */
static int	eter_max_seqscan_capture = 0;

/* Per-database SSI-WAL path, so each database drains only its own captures. */
static void
eter_ssi_wal_path(char *buf, size_t len)
{
	snprintf(buf, len, "%s/eter_ssi.%u.wal", DataDir, MyDatabaseId);
}

/*
 * Resolve an (already-open) relation + heap tuple to the row's primary key as
 * comma-joined text in index-key order, or NULL if there is no usable PK. Reads
 * only the supplied tuple (no heap fetch), so the caller controls which tuple
 * version is keyed, the read-time copy captured by the hook, or a freshly
 * fetched one for the SQL utility. Opens the PK index (AccessShareLock); MUST NOT
 * be called while holding a buffer content lock (it is only invoked at
 * PRE_COMMIT / drain / SQL time, never inside the read hot path).
 */
static char *
eter_resolve_pk_from_tuple(Relation rel, HeapTuple tup)
{
	Relation	idx;
	Oid			pkidx;
	TupleDesc	td;
	StringInfoData pk;
	int			k;

	RelationGetIndexList(rel);	/* populates rd_pkindex */
	pkidx = rel->rd_pkindex;
	if (!OidIsValid(pkidx))
		return NULL;

	td = RelationGetDescr(rel);
	idx = index_open(pkidx, AccessShareLock);
	initStringInfo(&pk);
	for (k = 0; k < idx->rd_index->indnkeyatts; k++)
	{
		AttrNumber	attno = idx->rd_index->indkey.values[k];
		bool		isnull;
		Datum		d;
		Oid			typ,
					outfn;
		bool		varlena;

		if (attno <= 0)			/* expression PK column, unsupported */
			continue;
		d = heap_getattr(tup, attno, td, &isnull);
		if (isnull)
			continue;
		typ = TupleDescAttr(td, attno - 1)->atttypid;
		getTypeOutputInfo(typ, &outfn, &varlena);
		if (pk.len > 0)
			appendStringInfoChar(&pk, ',');
		appendStringInfoString(&pk, OidOutputFunctionCall(outfn, d));
	}
	index_close(idx, AccessShareLock);

	if (pk.len == 0)
	{
		pfree(pk.data);
		return NULL;
	}
	return pk.data;				/* palloc'd by initStringInfo */
}

/*
 * Fetch the physical tuple at (reloid, blk, off) under SnapshotAny and resolve
 * its PK. Used only by the eter.resolve_pk() SQL utility now (read↔write
 * matching uses the read-time copy stashed by eter_tuple_read). Carries the
 * drain-time staleness caveat if called late (slot may have been reused).
 */
static char *
eter_resolve_pk_text(Oid reloid, BlockNumber blk, OffsetNumber off)
{
	Relation	rel;
	Buffer		buf = InvalidBuffer;
	HeapTupleData tup;
	char	   *result;

	rel = try_relation_open(reloid, AccessShareLock);
	if (rel == NULL)
		return NULL;

	ItemPointerSet(&tup.t_self, blk, off);
	if (!heap_fetch(rel, SnapshotAny, &tup, &buf, false))
	{
		relation_close(rel, AccessShareLock);
		return NULL;
	}
	result = eter_resolve_pk_from_tuple(rel, &tup);
	ReleaseBuffer(buf);
	relation_close(rel, AccessShareLock);
	return result;
}

/*
 * Read-time PK capture (closes the read→PRE_COMMIT window of the eager scheme).
 * eter_tuple_read() fires from the patched PredicateLockTID the instant a
 * tuple SIREAD lock is taken, while the scan still holds the buffer, so we may
 * NOT touch the catalog here. We just heap_copytuple() the live tuple (lock-free)
 * into a per-transaction stash keyed by the lock target (reloid, blk, off). The
 * copy is OUR memory, immune to later vacuum/line-pointer reuse. At PRE_COMMIT
 * (no buffer lock) eter_ssi_capture() resolves the PK from this copy.
 */
typedef struct EterReadKey
{
	Oid			reloid;
	BlockNumber blk;
	OffsetNumber off;
} EterReadKey;

typedef struct EterReadEntry
{
	EterReadKey key;			/* must be first (hash key) */
	HeapTuple	tuple;			/* read-time copy, in EterPkCxt */
} EterReadEntry;

static HTAB *EterReadStash = NULL;
static MemoryContext EterPkCxt = NULL;

/*
 * Per-relation seqscan capture state (observe-precision lever 3). Declared
 * unconditionally (referenced by eter_reset_read_stash + eter_ssi_capture, which
 * compile in every build); only ever populated by eter_seqscan_read on the
 * patched engine. A relation present with overflow=false was captured COMPLETELY
 * per-row, so its coarse relation-level predicate target is suppressed at commit.
 */
typedef struct EterSeqRelEntry
{
	Oid			reloid;			/* hash key */
	int			count;			/* rows of this relation stashed so far */
	bool		overflow;		/* hit the cap → fall back to coarse for it */
} EterSeqRelEntry;

static HTAB *EterSeqScanRel = NULL;

/*
 * Indexes whose rows this transaction captured PRECISELY (observe-precision,
 * issue #192). A btree [Index Only] Scan takes its SIREAD lock on the INDEX, a
 * page target carrying no row identity, so the harvest can only resolve it to
 * "every write to the underlying table". Applied to an ordinary indexed read that
 * over-approximation is not merely coarse, it is wrong in effect: a single
 * `UPDATE ... WHERE id = $1` made its writer depend on the table's entire write
 * history, so a cohort of unrelated single-row writes classified 0 clean.
 *
 * eter_index_read() records an index here once it has produced a row we hold
 * precisely (a fetched heap tuple, already stashed by eter_tuple_read, or an
 * index-only row whose TID we stash below). At commit that index's coarse
 * relation line is redundant and is suppressed. An index that never appears here
 * produced no rows we can name: an empty scan that matched nothing (whose
 * predicate read is real and must still be surfaced), or a bitmap scan, which
 * reaches the heap by a different path), so it keeps the coarse line. That is
 * what keeps the harvest SOUND: suppression is driven by positive evidence of
 * precise capture, never by assumption.
 */
static HTAB *EterCoveredIdx = NULL;

#ifndef ETER_STRICT_ONLY
static bool EterInTupleHook = false;

static void
eter_tuple_read(Relation relation, HeapTuple tuple)
{
	EterReadKey key;
	EterReadEntry *entry;
	bool		found;
	MemoryContext old;

	/* Only capture when we are actually harvesting a read set. */
	if (!IsolationIsSerializable() && !eter_observe_mode)
		return;
	if (EterInTupleHook)		/* defensive: never re-enter */
		return;
	/* Heap tuples only (skip index/other relations); need a real tuple. */
	if (tuple == NULL || tuple->t_data == NULL)
		return;

	EterInTupleHook = true;

	if (EterPkCxt == NULL)
		EterPkCxt = AllocSetContextCreate(TopMemoryContext,
											 "eter_ssi read PKs",
											 ALLOCSET_SMALL_SIZES);
	if (EterReadStash == NULL)
	{
		HASHCTL		ctl;

		MemSet(&ctl, 0, sizeof(ctl));
		ctl.keysize = sizeof(EterReadKey);
		ctl.entrysize = sizeof(EterReadEntry);
		ctl.hcxt = EterPkCxt;
		EterReadStash = hash_create("eter_ssi read stash", 256, &ctl,
									   HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
	}

	MemSet(&key, 0, sizeof(key));
	key.reloid = RelationGetRelid(relation);
	key.blk = ItemPointerGetBlockNumber(&tuple->t_self);
	key.off = ItemPointerGetOffsetNumber(&tuple->t_self);

	entry = (EterReadEntry *) hash_search(EterReadStash, &key,
											 HASH_ENTER, &found);
	if (!found)
	{
		/* heap_copytuple only reads the pinned tuple + allocates, no catalog. */
		old = MemoryContextSwitchTo(EterPkCxt);
		entry->tuple = heap_copytuple(tuple);
		MemoryContextSwitchTo(old);
	}

	EterInTupleHook = false;
}

/*
 * Per-row seqscan read capture (observe-precision lever 3). A seqscan locks the
 * whole relation rather than per-tuple, so eter_seqscan_read() captures each
 * returned row into the same EterReadStash as eter_tuple_read(), but bounded:
 * once a relation's captured count exceeds eter_max_seqscan_capture we stop (the
 * `overflow` flag) and let eter_ssi_capture() emit the coarse relation line.
 */
static void
eter_seqscan_read(Relation relation, HeapTuple tuple)
{
	EterReadKey key;
	EterReadEntry *entry;
	EterSeqRelEntry *seqrel;
	bool		found;
	MemoryContext old;

	/* Only capture when we are actually harvesting a read set. */
	if (!IsolationIsSerializable() && !eter_observe_mode)
		return;
	if (EterInTupleHook)		/* defensive: never re-enter */
		return;
	if (tuple == NULL || tuple->t_data == NULL)
		return;
	/*
	 * Skip system catalogs: they are never undo targets, are seqscanned
	 * constantly (planning, the drain's own SPI), and capturing them is pure
	 * overhead. User relations (incl. tracked tables) are >= FirstNormalObjectId.
	 */
	if (relation->rd_id < FirstNormalObjectId)
		return;

	EterInTupleHook = true;

	if (EterPkCxt == NULL)
		EterPkCxt = AllocSetContextCreate(TopMemoryContext,
										   "eter_ssi read PKs",
										   ALLOCSET_SMALL_SIZES);
	if (EterSeqScanRel == NULL)
	{
		HASHCTL		ctl;

		MemSet(&ctl, 0, sizeof(ctl));
		ctl.keysize = sizeof(Oid);
		ctl.entrysize = sizeof(EterSeqRelEntry);
		ctl.hcxt = EterPkCxt;
		EterSeqScanRel = hash_create("eter_ssi seqscan rels", 32, &ctl,
									 HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
	}
	if (EterReadStash == NULL)
	{
		HASHCTL		ctl;

		MemSet(&ctl, 0, sizeof(ctl));
		ctl.keysize = sizeof(EterReadKey);
		ctl.entrysize = sizeof(EterReadEntry);
		ctl.hcxt = EterPkCxt;
		EterReadStash = hash_create("eter_ssi read stash", 256, &ctl,
									HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
	}

	/* Per-relation cap: bound the per-row stash so a huge scan can't blow memory. */
	seqrel = (EterSeqRelEntry *) hash_search(EterSeqScanRel, &relation->rd_id,
											 HASH_ENTER, &found);
	if (!found)
	{
		seqrel->count = 0;
		seqrel->overflow = false;
	}
	if (seqrel->overflow)
	{
		EterInTupleHook = false;
		return;					/* already fell back to coarse for this relation */
	}
	if (eter_max_seqscan_capture <= 0 ||
		seqrel->count >= eter_max_seqscan_capture)
	{
		seqrel->overflow = true;	/* cap hit → coarse relation line at commit */
		EterInTupleHook = false;
		return;
	}

	MemSet(&key, 0, sizeof(key));
	key.reloid = RelationGetRelid(relation);
	key.blk = ItemPointerGetBlockNumber(&tuple->t_self);
	key.off = ItemPointerGetOffsetNumber(&tuple->t_self);

	entry = (EterReadEntry *) hash_search(EterReadStash, &key,
										  HASH_ENTER, &found);
	if (!found)
	{
		old = MemoryContextSwitchTo(EterPkCxt);
		entry->tuple = heap_copytuple(tuple);
		MemoryContextSwitchTo(old);
		seqrel->count++;
	}

	EterInTupleHook = false;
}

/*
 * Index read capture (observe-precision, issues #175 + #192). Fires from the
 * patched index AM once an index scan has produced a row, naming the index that
 * produced it.
 *
 * fetched=true: a visible heap tuple came back through this index, so
 * eter_tuple_read() has already stashed it with its live copy. Nothing to stash;
 * we only record that this index is precisely covered.
 *
 * fetched=false: an Index Only Scan answered from an all-visible page, so no heap
 * tuple was ever read and eter_tuple_read() never fired. Stash the heap TID with
 * no tuple copy; eter_ssi_capture() resolves the PK from the heap at PRE_COMMIT,
 * which is read-time accurate here because the row is all-visible and still
 * visible to our own snapshot, so vacuum cannot reclaim the line pointer while we
 * run. This is what lets the coarse index line be dropped without reopening the
 * index-only false clean.
 *
 * A bitmap index scan also reports fetched=true, but with no heap relation or TID
 * (it has neither): its rows are predicate-locked, and so stashed, by the bitmap
 * HEAP scan, so the index only needs marking as covered.
 *
 * KNOWN BOUNDARY: capture stops once SSI promotes to a RELATION-level lock, since
 * PredicateLockTID returns before the read hook when a relation lock already
 * covers the tuple. That promotion emits its own coarse heap-relation line, which
 * is NOT suppressed here (it is not redundant, the rows behind it really were not
 * captured), so a read wide enough to promote still over-approximates. Sound, and
 * tunable with max_pred_locks_per_relation / max_pred_locks_per_transaction.
 */
static void
eter_index_read(Relation heapRelation, ItemPointer tid, Oid indexoid,
				bool fetched)
{
	EterReadKey key;
	EterReadEntry *entry;
	bool		found;

	/* Only capture when we are actually harvesting a read set. */
	if (!IsolationIsSerializable() && !eter_observe_mode)
		return;
	/* User relations only, mirroring eter_seqscan_read. */
	if (!OidIsValid(indexoid) || indexoid < FirstNormalObjectId)
		return;

	if (EterPkCxt == NULL)
		EterPkCxt = AllocSetContextCreate(TopMemoryContext,
										  "eter_ssi read PKs",
										  ALLOCSET_SMALL_SIZES);

	/*
	 * Nothing to stash for a fetched row (eter_tuple_read already holds it) nor
	 * for a bitmap scan, which reports the index alone and leaves its rows to
	 * the heap side. Both only need the index marked covered below.
	 */
	if (!fetched)
	{
		/*
		 * An index-only row we cannot stash is a row we cannot name, so do NOT
		 * mark the index covered: leave it to the coarse relation line rather
		 * than suppress a read we failed to capture.
		 */
		if (heapRelation == NULL || tid == NULL || !ItemPointerIsValid(tid) ||
			heapRelation->rd_id < FirstNormalObjectId)
			return;

		if (EterReadStash == NULL)
		{
			HASHCTL		ctl;

			MemSet(&ctl, 0, sizeof(ctl));
			ctl.keysize = sizeof(EterReadKey);
			ctl.entrysize = sizeof(EterReadEntry);
			ctl.hcxt = EterPkCxt;
			EterReadStash = hash_create("eter_ssi read stash", 256, &ctl,
										HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
		}

		MemSet(&key, 0, sizeof(key));
		key.reloid = RelationGetRelid(heapRelation);
		key.blk = ItemPointerGetBlockNumber(tid);
		key.off = ItemPointerGetOffsetNumber(tid);

		entry = (EterReadEntry *) hash_search(EterReadStash, &key,
											  HASH_ENTER, &found);
		/*
		 * No tuple to copy (that is the point of an index-only scan), so leave
		 * the PK to the PRE_COMMIT heap fetch. Never clobber an existing entry:
		 * if the same row was also fetched, its read-time copy is stronger.
		 */
		if (!found)
			entry->tuple = NULL;
	}

	if (EterCoveredIdx == NULL)
	{
		HASHCTL		ctl;

		MemSet(&ctl, 0, sizeof(ctl));
		ctl.keysize = sizeof(Oid);
		ctl.entrysize = sizeof(Oid);
		ctl.hcxt = EterPkCxt;
		EterCoveredIdx = hash_create("eter_ssi covered indexes", 32, &ctl,
									 HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
	}
	(void) hash_search(EterCoveredIdx, &indexoid, HASH_ENTER, NULL);
}
#endif							/* !ETER_STRICT_ONLY */

/* Drop the per-transaction read stash (called at every transaction end). */
static void
eter_reset_read_stash(void)
{
	if (EterReadStash != NULL)
	{
		hash_destroy(EterReadStash);
		EterReadStash = NULL;
	}
	if (EterSeqScanRel != NULL)
	{
		hash_destroy(EterSeqScanRel);
		EterSeqScanRel = NULL;
	}
	if (EterCoveredIdx != NULL)
	{
		hash_destroy(EterCoveredIdx);
		EterCoveredIdx = NULL;
	}
	if (EterPkCxt != NULL)
		MemoryContextReset(EterPkCxt);
}

/*
 * Hex transport for the SSI-WAL: a resolved PK is arbitrary text (could contain
 * tabs/newlines), but the WAL is a tab-delimited line file, so the PK field is
 * hex-encoded on write and decoded on drain. Keeps the file format trivially
 * parseable without quoting rules.
 */
static const char eter_hexdig[] = "0123456789abcdef";

static void
eter_hex_encode(const char *src, int len, char *dst)
{
	int			i;

	for (i = 0; i < len; i++)
	{
		dst[2 * i] = eter_hexdig[(unsigned char) src[i] >> 4];
		dst[2 * i + 1] = eter_hexdig[(unsigned char) src[i] & 0x0f];
	}
	dst[2 * len] = '\0';
}

static int
eter_hexval(char c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

/* Decode hex `src` into a palloc'd, nul-terminated string. */
static char *
eter_hex_decode(const char *src)
{
	int			slen = strlen(src);
	int			olen = slen / 2;
	char	   *out = palloc(olen + 1);
	int			i;

	for (i = 0; i < olen; i++)
	{
		int			hi = eter_hexval(src[2 * i]);
		int			lo = eter_hexval(src[2 * i + 1]);

		if (hi < 0 || lo < 0)
		{
			out[i] = '\0';
			return out;
		}
		out[i] = (char) ((hi << 4) | lo);
	}
	out[olen] = '\0';
	return out;
}

/*
 * At PRE_COMMIT: append this transaction's SIREAD predicate-lock targets to the
 * SSI-WAL. One line per (reader_xid, reloid, block, offset, locktype, read_pk),
 * where read_pk is the row's primary key resolved EAGERLY here, while the read
 * tuple is still live (no vacuum has run since the read), hex-encoded, or "-"
 * for non-tuple (page/relation) targets. Resolving at capture rather than at
 * drain is what makes read↔write matching sound: the drain runs arbitrarily
 * later and races vacuum/HOT line-pointer reuse, which silently mis-resolves a
 * stale ctid to a different row (the false-clean the completeness harness found).
 */
static void
eter_ssi_capture(void)
{
	TransactionId myxid;
	PREDICATELOCKTARGETTAG *tags;
	int			ntags;
	char		path[MAXPGPATH];
	FILE	   *f;
	int			i;
	bool		use_stash;

	/*
	 * Capture when this transaction can hold SIREAD predicate locks: either it
	 * is SERIALIZABLE (strict mode) or the EterDB-patched engine is in
	 * observe mode (locks acquired under any isolation level).
	 */
	if (!IsolationIsSerializable() && !eter_observe_mode)
		return;

	/* Read-only transactions get no xid; they are exempt by construction. */
	myxid = GetTopTransactionIdIfAny();
	if (!TransactionIdIsValid(myxid))
		return;

	/*
	 * Enumerate THIS transaction's predicate-lock targets. On the patched
	 * engine we walk our own per-xact lock list directly
	 * (EterGetMyPredicateLockTargets), O(my locks) under one shared lock,
	 * avoiding GetPredicateLockStatusData()'s whole-cluster hash walk + 17-lock
	 * acquisition on every commit (the measured observe write-path bottleneck).
	 * On the stock strict-only build that export is absent, so fall back to the
	 * global snapshot filtered to our own vxid (the original strict-mode path).
	 * Building with -DETER_HARVEST_GLOBAL forces that same global path on the
	 * patched engine too, used only to A/B the harvest cost against the own-locks
	 * walk (same engine binary, swap only the dylib); never in a shipped build.
	 */
#if defined(ETER_STRICT_ONLY) || defined(ETER_HARVEST_GLOBAL)
	{
		PredicateLockData *data;
		VirtualTransactionId myvxid;

		GET_VXID_FROM_PGPROC(myvxid, *MyProc);
		data = GetPredicateLockStatusData();
		if (data == NULL || data->nelements == 0)
			return;
		tags = (PREDICATELOCKTARGETTAG *)
			palloc(sizeof(PREDICATELOCKTARGETTAG) * data->nelements);
		ntags = 0;
		for (i = 0; i < data->nelements; i++)
			if (VirtualTransactionIdEquals(data->xacts[i].vxid, myvxid))
				tags[ntags++] = data->locktags[i];
	}
#else
	tags = EterGetMyPredicateLockTargets(&ntags);
#endif

	/*
	 * Emit per ROW actually read (from the read-time stash) when we have it,
	 * NOT per predicate-lock target. Postgres coarsens SIREAD locks tuple→page
	 * (max_pred_locks_per_page, default 2) the moment a transaction reads more
	 * than a couple of rows on a page, so the HELD targets are mostly page-level
	 * and carry no row identity, and the store (no ctid map) is forced to
	 * over-approximate a page read to "conflicts with every write to the table".
	 * Under observe at realistic read volume that collapses surgical precision:
	 * one ordinary read makes a table's whole write history und-refusable. The
	 * read-time hook already stashed every individual tuple read with its live
	 * copy, immune to that coarsening, so emit one precise tuple line per stash
	 * entry. RELATION-level held targets are still emitted coarsely: a relation
	 * predicate lock means heapam stopped per-tuple locking (a large seqscan), so
	 * the stash does NOT cover those rows and table-level is the only sound choice.
	 * INDEX-relation held targets (page or relation) are emitted coarsely too,
	 * resolved to their heap table: an Index Only Scan satisfied from the
	 * visibility map fetches no heap tuple, so the read left no stash row and the
	 * only record of it is the SIREAD lock on the index (issue #175).
	 */
	use_stash = (EterReadStash != NULL && hash_get_num_entries(EterReadStash) > 0);

	if ((tags == NULL || ntags == 0) && !use_stash)
		return;

	eter_ssi_wal_path(path, sizeof(path));
	f = AllocateFile(path, "a");
	if (f == NULL)
	{
		ereport(WARNING,
				(errmsg("eter_ssi: could not open SSI-WAL \"%s\": %m", path)));
		return;
	}

	if (use_stash)
	{
		HASH_SEQ_STATUS seq;
		EterReadEntry *e;
		Relation	rel = NULL;
		Oid			rel_open = InvalidOid;

		/* One precise tuple line per row read (PK from the read-time copy). */
		hash_seq_init(&seq, EterReadStash);
		while ((e = (EterReadEntry *) hash_seq_search(&seq)) != NULL)
		{
			char	   *pktext = NULL;
			char	   *pkhex = NULL;
			char	   *pkfield = "-";

			if (e->key.reloid != rel_open)
			{
				if (rel != NULL)
					relation_close(rel, AccessShareLock);
				rel = try_relation_open(e->key.reloid, AccessShareLock);
				rel_open = e->key.reloid;
			}
			if (rel != NULL && e->tuple != NULL)
				/* trust the read-time copy: NULL here means no/expression PK,
				 * which must emit "-" (table-level), NOT a stale heap re-fetch. */
				pktext = eter_resolve_pk_from_tuple(rel, e->tuple);
			else if (rel != NULL)	/* copy gone → PRE_COMMIT fetch (read-time accurate) */
				pktext = eter_resolve_pk_text(e->key.reloid, e->key.blk, e->key.off);

			if (pktext != NULL)
			{
				int			l = strlen(pktext);

				pkhex = palloc(2 * l + 1);
				eter_hex_encode(pktext, l, pkhex);
				pkfield = pkhex;
				pfree(pktext);
			}
			fprintf(f, "%u\t%u\t%u\t%u\t%d\t%s\n",
					(uint32) myxid, (uint32) e->key.reloid,
					(uint32) e->key.blk, (uint32) e->key.off,
					PREDLOCKTAG_TUPLE, pkfield);
			if (pkhex != NULL)
				pfree(pkhex);
		}
		if (rel != NULL)
			relation_close(rel, AccessShareLock);

		/*
		 * Coarse (relation / index) held targets. Two kinds add information the
		 * per-tuple stash lines above do not carry:
		 *
		 *  - RELATION targets on a HEAP: a seqscan locks the whole relation. By
		 *    default this over-approximates to "conflicts with every write to the
		 *    table," but observe-precision lever 3 captures each row a seqscan
		 *    returns (eter_seqscan_read), so when a relation was COMPLETELY
		 *    captured per-tuple (present in EterSeqScanRel and NOT overflowed) the
		 *    precise tuple lines already represent every row read, suppress the
		 *    coarse line. Relations that overflowed the cap, or were locked by a
		 *    samplescan / a path that did not feed the hook, still emit coarsely.
		 *
		 *  - INDEX targets (page OR relation): an Index [Only] Scan takes its
		 *    SIREAD lock on the INDEX relation. When the scan is satisfied without
		 *    a heap fetch (Index Only Scan, Heap Fetches: 0) no heap tuple ever
		 *    reached eter_tuple_read, so NO stash row represents it, and the
		 *    index's oid is never in the stash (which only holds heap reloids) by
		 *    construction. These are exactly the reads the per-tuple path cannot
		 *    cover (issue #175). Resolve the index to its heap table and emit a
		 *    relation-level over-approximation (the read conflicts with every write
		 *    to that table), the safe direction, same contract as the seqscan
		 *    fallback. Precise (table, pk) recovery from the index tuple is a
		 *    deferred follow-up.
		 *
		 * TUPLE and heap-PAGE targets are skipped: they are superseded by the
		 * stash rows (every heap tuple that took a SIREAD lock reached the hook).
		 */
		for (i = 0; i < ntags; i++)
		{
			PREDICATELOCKTARGETTAG tag = tags[i];
			int			tty;
			Oid			rrelid;
			Oid			heaprel;

			if (GET_PREDICATELOCKTARGETTAG_DB(tag) != MyDatabaseId)
				continue;

			tty = (int) GET_PREDICATELOCKTARGETTAG_TYPE(tag);
			if (tty == PREDLOCKTAG_TUPLE)
				continue;		/* heap tuple, superseded by a stash row */

			rrelid = (Oid) GET_PREDICATELOCKTARGETTAG_RELATION(tag);

			/* Index target (page or relation): over-approx to the heap table. */
			heaprel = IndexGetRelation(rrelid, true);
			if (OidIsValid(heaprel))
			{
				/*
				 * Suppress the coarse line when this index is precisely covered:
				 * every row it produced is already a tuple line above, either
				 * fetched (stashed by eter_tuple_read) or index-only (stashed by
				 * eter_index_read). Emitting it anyway would say "this read
				 * conflicts with every write to the table", which is what made an
				 * ordinary `WHERE id = $1` read depend on a table's whole write
				 * history (issue #192). An index NOT recorded as covered produced
				 * no row we can name: an empty scan whose predicate read is real,
				 * or a bitmap scan, which reaches the heap another way, so it
				 * keeps the coarse line and the harvest stays sound.
				 */
				if (EterCoveredIdx != NULL &&
					hash_search(EterCoveredIdx, &rrelid, HASH_FIND, NULL) != NULL)
					continue;

				fprintf(f, "%u\t%u\t0\t0\t%d\t-\n",
						(uint32) myxid, (uint32) heaprel, PREDLOCKTAG_RELATION);
				continue;
			}

			/* Heap relation: only a RELATION-level (seqscan) lock adds info. */
			if (tty != PREDLOCKTAG_RELATION)
				continue;		/* heap page, superseded by stash rows */

			if (EterSeqScanRel != NULL)
			{
				EterSeqRelEntry *sr = (EterSeqRelEntry *)
					hash_search(EterSeqScanRel, &rrelid, HASH_FIND, NULL);

				if (sr != NULL && !sr->overflow)
					continue;	/* fully captured per-row → coarse line redundant */
			}
			fprintf(f, "%u\t%u\t%u\t%u\t%d\t-\n",
					(uint32) myxid,
					(uint32) rrelid,
					(uint32) GET_PREDICATELOCKTARGETTAG_PAGE(tag),
					(uint32) GET_PREDICATELOCKTARGETTAG_OFFSET(tag),
					PREDLOCKTAG_RELATION);
		}

		FreeFile(f);
		return;
	}

	/*
	 * No read stash (stock strict-only build, or the hook never fired): the
	 * original target walk, tuple PK via a PRE_COMMIT heap fetch, page/relation
	 * coarse.
	 */
	for (i = 0; i < ntags; i++)
	{
		PREDICATELOCKTARGETTAG tag = tags[i];
		Oid			db;
		Oid			relid;
		BlockNumber blk;
		OffsetNumber off;
		int			ty;
		char	   *pkfield = "-";
		char	   *pkhex = NULL;

		db = GET_PREDICATELOCKTARGETTAG_DB(tag);
		if (db != MyDatabaseId)
			continue;

		relid = (Oid) GET_PREDICATELOCKTARGETTAG_RELATION(tag);
		blk = (BlockNumber) GET_PREDICATELOCKTARGETTAG_PAGE(tag);
		off = (OffsetNumber) GET_PREDICATELOCKTARGETTAG_OFFSET(tag);
		ty = (int) GET_PREDICATELOCKTARGETTAG_TYPE(tag);

		/*
		 * An index-relation page/relation target resolves to a relation-level
		 * read of the underlying heap table (issue #175): an Index Only Scan
		 * takes its SIREAD lock on the index, and matching joins on the heap oid.
		 * Tuple targets are always heap tuples, so skip the lookup for them.
		 */
		if (ty != PREDLOCKTAG_TUPLE)
		{
			Oid			heaprel = IndexGetRelation(relid, true);

			if (OidIsValid(heaprel))
			{
				relid = heaprel;
				blk = 0;
				off = 0;
				ty = PREDLOCKTAG_RELATION;
			}
		}

		if (ty == PREDLOCKTAG_TUPLE)
		{
			char	   *pktext = eter_resolve_pk_text(relid, blk, off);

			if (pktext != NULL)
			{
				int			l = strlen(pktext);

				pkhex = palloc(2 * l + 1);
				eter_hex_encode(pktext, l, pkhex);
				pkfield = pkhex;
				pfree(pktext);
			}
		}

		fprintf(f, "%u\t%u\t%u\t%u\t%d\t%s\n",
				(uint32) myxid,
				(uint32) relid,
				(uint32) blk,
				(uint32) off,
				ty,
				pkfield);

		if (pkhex != NULL)
			pfree(pkhex);
	}

	FreeFile(f);
}

static void
eter_ssi_xact_callback(XactEvent event, void *arg)
{
	if (event == XACT_EVENT_PRE_COMMIT)
		eter_ssi_capture();

	/* Free the per-transaction read-PK stash at every transaction end. */
	if (event == XACT_EVENT_COMMIT || event == XACT_EVENT_ABORT ||
		event == XACT_EVENT_PREPARE ||
		event == XACT_EVENT_PARALLEL_COMMIT || event == XACT_EVENT_PARALLEL_ABORT)
		eter_reset_read_stash();
}

/*
 * Background worker: periodically drain + derive the SSI graph for one database,
 * so dependencies appear without an explicit eter.refresh_dependencies() call.
 * One worker drains one database (eter_ssi.drain_database); multiple databases
 * would each need their own worker, a deliberate, documented limitation for now.
 */
void
eter_ssi_worker_main(Datum main_arg)
{
	pqsignal(SIGTERM, die);
	pqsignal(SIGHUP, SignalHandlerForConfigReload);
	BackgroundWorkerUnblockSignals();
	BackgroundWorkerInitializeConnection(eter_drain_database, NULL, 0);

#ifndef ETER_STRICT_ONLY
	/*
	 * The drain worker only READS eter.ssi_reads/history/dependencies to derive
	 * edges; it must not itself capture (self-noise in the SSI-WAL) and it must
	 * keep full parallelism for the derive joins. Exempt this session from observe
	 * mode regardless of any per-database default (ALTER DATABASE ... SET
	 * eter_observe_mode=on), which would otherwise also trip the serialize-under-
	 * observe planner_hook on every derive.
	 */
	SetConfigOption("eter_observe_mode", "off", PGC_USERSET, PGC_S_SESSION);
#endif

	for (;;)
	{
		(void) WaitLatch(MyLatch,
						 WL_LATCH_SET | WL_TIMEOUT | WL_EXIT_ON_PM_DEATH,
						 eter_drain_interval_ms, PG_WAIT_EXTENSION);
		ResetLatch(MyLatch);
		CHECK_FOR_INTERRUPTS();

		if (ConfigReloadPending)
		{
			ConfigReloadPending = false;
			ProcessConfigFile(PGC_SIGHUP);
		}

		/*
		 * Drain in its own transaction. Tolerate errors (e.g. the target DB has
		 * not installed eter_ssi yet) by aborting and retrying next tick.
		 */
		StartTransactionCommand();
		PushActiveSnapshot(GetTransactionSnapshot());
		PG_TRY();
		{
			if (SPI_connect() == SPI_OK_CONNECT)
			{
				SPI_execute("SELECT eter.refresh_dependencies()", false, 0);
				SPI_finish();
			}
			PopActiveSnapshot();
			CommitTransactionCommand();
		}
		PG_CATCH();
		{
			EmitErrorReport();
			FlushErrorState();
			AbortCurrentTransaction();
		}
		PG_END_TRY();
	}
}

/*
 * Observe capture is backend-local: it is in the leader's LocalPredicateLockHash
 * and is harvested at the leader's PRE_COMMIT. Parallel workers do NOT arm observe
 * (EterMaybeRegisterObserveXact bails on IsParallelWorker) and share no
 * SERIALIZABLEXACT with the leader, so any predicate lock a worker would take (the
 * per-tuple SIREAD locks of a parallel index/bitmap scan) is never captured - a
 * silent read-dependency miss, i.e. a false-clean. To keep observe capture COMPLETE,
 * plan observe-mode transactions serially: force max_parallel_workers_per_gather=0
 * for the duration of planning so every read happens in the one backend that
 * harvests. This only affects transactions that opted into observe mode; with
 * observe off the hook is a pass-through. (Analytics readers that don't need
 * dependency capture should run with observe off per-role - eter_observe_mode is
 * PGC_USERSET - and keep full parallelism.)
 *
 * Only built on the patched engine: on stock Postgres (ETER_STRICT_ONLY) observe
 * mode does not exist, so there is nothing to serialize.
 */
#ifndef ETER_STRICT_ONLY
static planner_hook_type prev_planner_hook = NULL;

static PlannedStmt *
eter_ssi_planner(Query *parse, const char *query_string, int cursorOptions,
				 ParamListInfo boundParams)
{
	PlannedStmt *result;
	int			save_mpwg = max_parallel_workers_per_gather;
	bool		forced = false;

	if (eter_observe_mode && !IsParallelWorker() &&
		max_parallel_workers_per_gather > 0)
	{
		max_parallel_workers_per_gather = 0;
		forced = true;
	}

	PG_TRY();
	{
		if (prev_planner_hook)
			result = prev_planner_hook(parse, query_string, cursorOptions, boundParams);
		else
			result = standard_planner(parse, query_string, cursorOptions, boundParams);
	}
	PG_FINALLY();
	{
		if (forced)
			max_parallel_workers_per_gather = save_mpwg;
	}
	PG_END_TRY();

	return result;
}
#endif							/* !ETER_STRICT_ONLY */

void
_PG_init(void)
{
	/* Capture hook: works whether loaded via session_ or shared_preload. */
	RegisterXactCallback(eter_ssi_xact_callback, NULL);

#ifndef ETER_STRICT_ONLY
	/*
	 * Serialize observe-mode planning so parallel workers never do uncaptured
	 * reads (see eter_ssi_planner). Only meaningful on the patched engine where
	 * eter_observe_mode exists.
	 */
	prev_planner_hook = planner_hook;
	planner_hook = eter_ssi_planner;
#endif

#ifndef ETER_STRICT_ONLY
	/*
	 * Read-time PK capture: the patched PredicateLockTID calls this when a tuple
	 * SIREAD lock is taken, so we copy the live tuple before any vacuum can reuse
	 * its slot (closing the read→PRE_COMMIT window). Only available on the patched
	 * engine; on stock Postgres (ETER_STRICT_ONLY) capture falls back to the
	 * PRE_COMMIT heap fetch.
	 */
	eter_tuple_read_hook = eter_tuple_read;
	/*
	 * Per-row seqscan capture: the patched heap_getnextslot calls this for each
	 * row a seqscan returns, so reads behind a relation-level predicate lock are
	 * captured precisely (bounded by eter_ssi.max_seqscan_capture) instead of
	 * over-approximated table-wide.
	 */
	eter_seqscan_read_hook = eter_seqscan_read;
	/*
	 * Index read capture: the patched index AM calls this once an index scan has
	 * produced a row, naming the index. It stashes index-only rows (which no heap
	 * fetch would surface) and marks the index precisely covered, so its coarse
	 * index-relation over-approximation can be dropped at commit (issue #192).
	 */
	eter_index_read_hook = eter_index_read;
#endif

	/*
	 * PGC_SIGHUP (not PGC_POSTMASTER): a POSTMASTER custom GUC can only be
	 * created during shared_preload startup, and would FATAL if this library is
	 * also loaded later via session_preload_libraries. SIGHUP is definable any
	 * time; the worker reads it once at postmaster startup, so changing it needs
	 * a restart to re-register the worker.
	 */
	DefineCustomStringVariable("eter_ssi.drain_database",
							   "Database whose SSI-WAL the background worker drains.",
							   NULL, &eter_drain_database, "",
							   PGC_SIGHUP, 0, NULL, NULL, NULL);
	DefineCustomIntVariable("eter_ssi.drain_interval_ms",
							"Interval between background SSI-WAL drains (ms).",
							NULL, &eter_drain_interval_ms, 1000, 50, 600000,
							PGC_SIGHUP, GUC_UNIT_MS, NULL, NULL, NULL);
	DefineCustomIntVariable("eter_ssi.max_seqscan_capture",
							"Max rows per relation a transaction's seqscan captures per-tuple before falling back to a coarse table-level read dependency.",
							"0 (default) disables per-row seqscan capture, reads behind a seqscan stay table-level over-approximations, preserving full read-edge recall. Raising it suppresses the coarse line for fully-captured seqscans (a tighter dependent set) at the cost of exposing the read->PRE_COMMIT residual.",
							&eter_max_seqscan_capture, 0, 0, INT_MAX,
							PGC_USERSET, 0, NULL, NULL, NULL);
	MarkGUCPrefixReserved("eter_ssi");

	/* The drain worker requires shared_preload_libraries + a configured DB. */
	if (!process_shared_preload_libraries_in_progress)
		return;
	if (eter_drain_database == NULL || eter_drain_database[0] == '\0')
		return;

	{
		BackgroundWorker worker;

		memset(&worker, 0, sizeof(worker));
		worker.bgw_flags = BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION;
		worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
		worker.bgw_restart_time = 5;
		snprintf(worker.bgw_library_name, BGW_MAXLEN, "eter_ssi");
		snprintf(worker.bgw_function_name, BGW_MAXLEN, "eter_ssi_worker_main");
		snprintf(worker.bgw_name, BGW_MAXLEN, "eter_ssi drain worker");
		snprintf(worker.bgw_type, BGW_MAXLEN, "eter_ssi drain");
		worker.bgw_main_arg = (Datum) 0;
		RegisterBackgroundWorker(&worker);
	}
}

/*
 * How many SSI-WAL records to accumulate before one set-based INSERT. The drain
 * used to do one INSERT per line (one SPI round-trip per read target), which made
 * it the write-path bottleneck under sustained observe capture, the SSI-WAL
 * backed up ~129 MB in 60s because ingest could not keep pace (perf report). We
 * now coalesce up to ETER_DRAIN_BATCH rows into a single array-parameter
 * `unnest` INSERT, cutting round-trips and per-statement planning by ~3 orders of
 * magnitude. 1024 keeps the constructed arrays comfortably small while amortising
 * SPI/executor overhead.
 */
#define ETER_DRAIN_BATCH 1024

/*
 * Insert one batch of parsed read targets with a single set-based statement:
 * unnest the six column arrays so N rows cost one SPI call instead of N. Caller
 * builds the Datum arrays (and the per-element NULL flags for read_pk) in a
 * memory context it resets between batches; nothing here outlives the call.
 */
static void
eter_drain_flush(int n, Datum *xid, Datum *rel, Datum *blk,
					Datum *off, Datum *ty, Datum *pk, bool *pknull)
{
	Datum		arrvals[6];
	Oid			argtypes[6] = {INT8ARRAYOID, INT8ARRAYOID, INT8ARRAYOID,
							   INT4ARRAYOID, INT4ARRAYOID, TEXTARRAYOID};
	bool		pk_has_null = false;
	int			i;

	if (n == 0)
		return;

	arrvals[0] = PointerGetDatum(construct_array(xid, n, INT8OID, 8, true, TYPALIGN_DOUBLE));
	arrvals[1] = PointerGetDatum(construct_array(rel, n, INT8OID, 8, true, TYPALIGN_DOUBLE));
	arrvals[2] = PointerGetDatum(construct_array(blk, n, INT8OID, 8, true, TYPALIGN_DOUBLE));
	arrvals[3] = PointerGetDatum(construct_array(off, n, INT4OID, 4, true, TYPALIGN_INT));
	arrvals[4] = PointerGetDatum(construct_array(ty, n, INT4OID, 4, true, TYPALIGN_INT));

	for (i = 0; i < n; i++)
		if (pknull[i])
		{
			pk_has_null = true;
			break;
		}

	if (pk_has_null)
	{
		int			dims[1] = {n};
		int			lbs[1] = {1};

		arrvals[5] = PointerGetDatum(construct_md_array(pk, pknull, 1, dims, lbs,
														TEXTOID, -1, false, TYPALIGN_INT));
	}
	else
		arrvals[5] = PointerGetDatum(construct_array(pk, n, TEXTOID, -1, false, TYPALIGN_INT));

	SPI_execute_with_args(
						   "INSERT INTO eter.ssi_reads "
						   "(reader_xid, reloid, blk, off, locktype, read_pk) "
						   "SELECT * FROM unnest($1::bigint[], $2::bigint[], $3::bigint[], "
						   "$4::int[], $5::int[], $6::text[])",
						   6, argtypes, arrvals, NULL, false, 0);
}

/*
 * eter.drain_ssi_wal() -> int
 * Ingest the append-only SSI-WAL into eter.ssi_reads, then truncate it.
 * Returns the number of read-target records ingested. Runs off the hot path.
 *
 * Records are parsed and coalesced into ETER_DRAIN_BATCH-sized set-based
 * INSERTs (see eter_drain_flush) rather than one INSERT per line, the drain
 * is what bounds sustainable write-side observe capture, so it must ingest in
 * bulk to keep pace with the SSI-WAL.
 */
PG_FUNCTION_INFO_V1(eter_ssi_drain);

Datum
eter_ssi_drain(PG_FUNCTION_ARGS)
{
	char		path[MAXPGPATH];
	FILE	   *f;
	char		line[1024];
	int			count = 0;
	int			n = 0;
	Datum		xid[ETER_DRAIN_BATCH];
	Datum		rel[ETER_DRAIN_BATCH];
	Datum		blk[ETER_DRAIN_BATCH];
	Datum		off[ETER_DRAIN_BATCH];
	Datum		ty[ETER_DRAIN_BATCH];
	Datum		pk[ETER_DRAIN_BATCH];
	bool		pknull[ETER_DRAIN_BATCH];
	MemoryContext batchctx;
	MemoryContext oldctx;

	eter_ssi_wal_path(path, sizeof(path));

	f = AllocateFile(path, "r");
	if (f == NULL)
		PG_RETURN_INT32(0);		/* nothing captured yet */

	if (SPI_connect() != SPI_OK_CONNECT)
		elog(ERROR, "eter_ssi: SPI_connect failed");

	/*
	 * Decoded PKs and the per-batch arrays are built here and freed wholesale by
	 * resetting this context after each flush, so the drain's memory stays flat
	 * regardless of how large the SSI-WAL grew.
	 */
	batchctx = AllocSetContextCreate(CurrentMemoryContext,
									 "eter_ssi drain batch",
									 ALLOCSET_DEFAULT_SIZES);
	oldctx = MemoryContextSwitchTo(batchctx);

	while (fgets(line, sizeof(line), f) != NULL)
	{
		unsigned int rxid,
					rrel,
					rblk,
					roff;
		int			rty;
		char		pkhex[512];

		/* Current 6-field format (with read_pk); tolerate the old 5-field one. */
		if (sscanf(line, "%u\t%u\t%u\t%u\t%d\t%511s", &rxid, &rrel, &rblk, &roff, &rty, pkhex) != 6)
		{
			if (sscanf(line, "%u\t%u\t%u\t%u\t%d", &rxid, &rrel, &rblk, &roff, &rty) != 5)
				continue;
			pkhex[0] = '-';
			pkhex[1] = '\0';
		}

		xid[n] = Int64GetDatum((int64) rxid);
		rel[n] = Int64GetDatum((int64) rrel);
		blk[n] = Int64GetDatum((int64) rblk);
		off[n] = Int32GetDatum((int32) roff);
		ty[n] = Int32GetDatum(rty);
		if (pkhex[0] == '-' && pkhex[1] == '\0')
		{
			pk[n] = (Datum) 0;
			pknull[n] = true;
		}
		else
		{
			pk[n] = CStringGetTextDatum(eter_hex_decode(pkhex));
			pknull[n] = false;
		}
		n++;
		count++;

		if (n == ETER_DRAIN_BATCH)
		{
			eter_drain_flush(n, xid, rel, blk, off, ty, pk, pknull);
			n = 0;
			MemoryContextReset(batchctx);
		}
	}

	if (n > 0)
		eter_drain_flush(n, xid, rel, blk, off, ty, pk, pknull);

	MemoryContextSwitchTo(oldctx);
	MemoryContextDelete(batchctx);

	FreeFile(f);

	/* Truncate the WAL now that it is ingested. */
	f = AllocateFile(path, "w");
	if (f != NULL)
		FreeFile(f);

	SPI_finish();
	PG_RETURN_INT32(count);
}

/*
 * eter.resolve_pk(reloid bigint, blk bigint, off int) -> text
 *
 * SQL utility wrapper over eter_resolve_pk_text(): resolve a physical heap
 * location to the row's primary key as comma-joined text in index-key order.
 *
 * NOTE: read↔write matching no longer calls this at drain time, the PK is now
 * resolved EAGERLY at the reader's PRE_COMMIT (see eter_ssi_capture) and
 * stored in eter.ssi_reads.read_pk, because a drain-time resolution races
 * vacuum/line-pointer reuse and mis-resolves stale ctids (the false-clean the
 * completeness harness found). This function is kept for diagnostics and as a
 * point-in-time helper; it carries the same staleness caveat if called late.
 * Returns NULL if the relation/tuple is gone or has no usable PK.
 */
PG_FUNCTION_INFO_V1(eter_ssi_resolve_pk);

Datum
eter_ssi_resolve_pk(PG_FUNCTION_ARGS)
{
	Oid			reloid = (Oid) PG_GETARG_INT64(0);
	BlockNumber blk = (BlockNumber) PG_GETARG_INT64(1);
	OffsetNumber off = (OffsetNumber) PG_GETARG_INT32(2);
	char	   *pk = eter_resolve_pk_text(reloid, blk, off);

	if (pk == NULL)
		PG_RETURN_NULL();
	PG_RETURN_TEXT_P(cstring_to_text(pk));
}
