# Offline-First SDK Design

**Date:** 2026-04-24
**Scope:** `frappe-mobile-sdk` (Flutter SDK package)
**Status:** Design — approved by stakeholder, ready for phased implementation plans
**Target:** any Frappe/ERPNext consumer app; not specific to any one SNF deployment

---

## 1. Context & motivation

The SDK at v1.1.0 has a partial offline story:
- A single generic `documents` table with a JSON `data` blob per row (`lib/src/database/app_database.dart:135`).
- Sequential, serial pull (`sync_service.dart:154`: one `get_list` with `limit=1000`, no batching).
- Sequential, serial push (`sync_service.dart:52-128`): insertion-order create/update/delete, no dependency resolution, no UUID→server-name rewrite, no retry.
- No failed-records tracking beyond an in-memory `SyncError` list.
- `LinkOptionService` is network-always (no DB fallback for pickers).
- `fetch_from` is wired (`form_builder.dart:593`) but only over network.
- Attachments upload immediately on pick (`attach_field.dart`); nothing queues a pending upload for offline-picked files.
- Logout unconditionally wipes the DB (`auth_service.dart:589`, `app_database.dart:233`) with no pending-sync guard.

This document specifies a complete offline-first data layer that supports **any** Frappe consumer app built on this SDK. The consumer app stays thin: declare home-screen entry points, rely on the SDK for all offline/sync/conflict behavior.

## 2. Goals and non-goals

### 2.1 Goals

1. **Complete offline data collection**: every CRUD operation works without network; syncs transparently when network returns.
2. **Per-doctype tables** with real columns (not JSON blobs), derived from DocType meta.
3. **Bounded initial sync**: pull closure of home-screen entry points following Link + Table + Table MultiSelect edges (transitive closure, no depth cap, no system-doctype exclusion).
4. **Device-aware concurrency** on low-end Android (2/4/8 concurrent HTTP).
5. **Parent-with-nested-children single-payload push** with topological ordering, UUID→server-name rewrite, server-side `mobile_uuid` dedup for idempotent inserts.
6. **Conflict handling** via auto last-write-wins with explicit user surface when auto-resolution fails.
7. **Unified read path**: one resolver serves `OfflineRepository.query`, Link pickers, `fetch_from`, and list screens — network-first + DB-side-effect write + DB-is-source-of-truth-at-read.
8. **Frappe-style filter parser** producing parameterized SQLite queries with null-parity, timespan resolution, AND+OR combination.
9. **Persistent outbox** that survives app kill; resumable pulls via cursor-based watermark.
10. **UI surface**: sync status bar, failed-records chip and dedicated screen, logout guard, blocking initial-sync progress, retry-all with priority ordering.
11. **Atomic wipe on logout** with guarded confirmation flow.

### 2.2 Non-goals (future scope)

- Tree operators in FilterParser (`descendants of`/`ancestors of`).
- Cross-doctype child-table filters.
- Dynamic filter values (`user.department`).
- Background sync via Android `WorkManager` (foreground only in v1).
- Real-time/websocket updates.
- Amendment (`amend_from`) flow.
- Print-format/PDF generation offline.
- Comments offline.
- Workflow transitions beyond `docstatus`.
- Server-side compression of list endpoints.

## 3. Architecture

### 3.1 Layering

```
┌─────────────────────────────────────────────────────────────┐
│ UI hooks (list chip, form banner, sync_status, logout,      │
│           init-sync progress)  — optional, replaceable       │
├─────────────────────────────────────────────────────────────┤
│ OfflineRepository (public read/write API)                   │
│ SyncController    (public control + state stream)           │
├─────────────────────────────────────────────────────────────┤
│ PullEngine │ PushEngine │ UnifiedResolver │ FilterParser    │
├─────────────────────────────────────────────────────────────┤
│ MetaService  (DocTypeMeta + DependencyGraph + migration)    │
├─────────────────────────────────────────────────────────────┤
│ ConcurrencyPool × 2 (Pull, Push)     network                │
│ WriteQueue × doctype                 serial disk per doctype│
│ IsolateParser                        JSON on isolate        │
│ ConnectivityWatcher                  connectivity_plus      │
│ SessionUser                          login state            │
├─────────────────────────────────────────────────────────────┤
│ AppDatabase (sqflite) — per-doctype + system tables         │
├─────────────────────────────────────────────────────────────┤
│ FrappeClient (api/*) — HTTP, auth, endpoints                │
└─────────────────────────────────────────────────────────────┘
                          │
                    Frappe server (stock v15+)
                    — optional consumer hooks for stricter
                      idempotency (see §10)
```

### 3.2 Three dataflows

**Pull.** Entry points from home-screen config → transitive closure on `{Link, Table, Table MultiSelect}` edges → per-doctype cursor-based paginated `GET /api/resource/<doctype>` (500/page) through `PullPool` → JSON parsed in isolate → rows UPSERTed by `server_name` into `docs__<doctype>` via per-doctype `WriteQueue` transactions → watermark advances only after entire doctype pull completes.

**Push.** Every local write (save, submit, cancel, delete, attachment pick) writes to `docs__<doctype>` AND appends an `outbox` row in one transaction. `PushEngine` drains the outbox: groups pending rows into topological tiers using `doctype_meta.dep_graph_json`, dispatches per-row HTTP through `PushPool` (insert/update/submit/cancel/delete); inside each dispatched row, payload is assembled from DB, Link fields rewritten from `mobile_uuid` to `server_name`, children nested under their `parentfield`, attachments uploaded first and their `file_url` inlined. On response, `server_name` + `modified` + child-row names written back.

**Read.** `OfflineRepository.query(...)` (used by list screens) and the same path for Link pickers and `fetch_from`: synchronously reads from DB; if online, fires a deduplicated background API refresh that UPSERTs fresh rows into DB via `WriteQueue`. Caller renders from DB. Merged view exposes local `dirty`/`blocked`/`conflict` rows with precedence over `synced`; `failed` rows excluded unless asked.

## 4. Data model

### 4.1 Doctype → table-name normalization

Doctype names may contain spaces, slashes, etc. Normalized for SQLite: lowercase, spaces/non-alphanumeric → `_`. Collision-checked at creation time with numeric suffix. Mapping persisted on `doctype_meta.table_name`.

### 4.2 Per-doctype table (parent)

Always-present system columns:

```sql
CREATE TABLE docs__<doctype> (
  mobile_uuid     TEXT PRIMARY KEY,
  server_name     TEXT,                              -- null until synced
  sync_status     TEXT NOT NULL DEFAULT 'dirty',     -- dirty|synced|failed|conflict|blocked
  sync_error      TEXT,
  sync_attempts   INTEGER NOT NULL DEFAULT 0,
  sync_op         TEXT,                              -- last enqueued op
  docstatus       INTEGER NOT NULL DEFAULT 0,        -- 0|1|2
  modified        TEXT,                              -- server ISO8601 (conflict check)
  local_modified  INTEGER NOT NULL,                  -- epoch ms
  pulled_at       INTEGER,
  -- plus: one column per DocField (per mapping in 4.5)
  -- plus: optional <field>__is_local INTEGER for Link/Dynamic Link fields
  -- plus: optional <field>__norm TEXT for fields in search_fields / title_field
);
CREATE UNIQUE INDEX ix_<doctype>_server_name ON docs__<doctype>(server_name)
  WHERE server_name IS NOT NULL;
CREATE INDEX ix_<doctype>_status   ON docs__<doctype>(sync_status);
CREATE INDEX ix_<doctype>_modified ON docs__<doctype>(modified);
-- plus auto-indexes capped at 7/doctype (section 4.6)
```

Note: `draft` is *not* a persisted `sync_status` — it's the form-in-progress state held in memory by `FormScreen` before user taps save. Once saved, the row lands in this table with `sync_status='dirty'` and an `outbox` row exists.

### 4.3 Per-child-doctype table

```sql
CREATE TABLE docs__<child> (
  mobile_uuid     TEXT PRIMARY KEY,
  server_name     TEXT,                              -- Frappe-generated child name
  parent_uuid     TEXT NOT NULL,
  parent_doctype  TEXT NOT NULL,
  parentfield     TEXT NOT NULL,
  idx             INTEGER NOT NULL,
  modified        TEXT,
  -- plus: one column per child DocField
);
CREATE UNIQUE INDEX ux_<child>_server_name ON docs__<child>(server_name)
  WHERE server_name IS NOT NULL;
CREATE UNIQUE INDEX ux_<child>_parent_slot ON docs__<child>(parent_uuid, parentfield, idx);
```

Children have no `sync_status` of their own. Any INSERT/UPDATE/DELETE on a row here marks the parent `dirty` and appends/collapses an `outbox` UPDATE for the parent in the same transaction. On parent pull, its children are **fully replaced** in a single transaction (`DELETE` + `INSERT` + parent `UPDATE`) — relational integrity guaranteed by the transaction boundary.

### 4.4 System tables

```sql
CREATE TABLE doctype_meta (
  doctype              TEXT PRIMARY KEY,
  table_name           TEXT NOT NULL,
  meta_json            TEXT NOT NULL,                -- full DocTypeMeta
  meta_watermark       TEXT,                         -- server's DocType.modified; drives migration
  dep_graph_json       TEXT,                         -- cached edges + tier
  last_ok_cursor       TEXT,                         -- JSON {modified, name}
  last_pull_started_at INTEGER,
  last_pull_ok_at      INTEGER,
  is_entry_point       INTEGER NOT NULL DEFAULT 0,
  is_child_table       INTEGER NOT NULL DEFAULT 0,
  record_count         INTEGER
);

CREATE TABLE outbox (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  doctype          TEXT    NOT NULL,
  mobile_uuid      TEXT    NOT NULL,
  server_name      TEXT,                             -- filled after INSERT succeeds
  operation        TEXT    NOT NULL,                 -- INSERT|UPDATE|SUBMIT|CANCEL|DELETE
  payload          TEXT,                             -- JSON snapshot at enqueue time
  state            TEXT    NOT NULL,                 -- see state enum in 5.2
  retry_count      INTEGER NOT NULL DEFAULT 0,
  last_attempt_at  INTEGER,
  error_message    TEXT,
  error_code       TEXT,                             -- see error_code enum below
  created_at       INTEGER NOT NULL
);
CREATE INDEX ix_outbox_state ON outbox(state, created_at);
CREATE INDEX ix_outbox_uuid  ON outbox(mobile_uuid);
-- error_code enum: NETWORK | TIMEOUT | TIMESTAMP_MISMATCH | LINK_EXISTS |
--                  PERMISSION_DENIED | VALIDATION | MANDATORY | UNKNOWN
-- Idempotency: handled via `mobile_uuid` on INSERT (server-side dedup, §10)
--   and via snapshot `modified` on UPDATE (Frappe's check_if_latest, §5.7).
--   No client-generated idempotency key required.
-- Dependency order: tiers computed in memory per run from current payload
--   (§5.2); no persistent depends_on column.

CREATE TABLE pending_attachments (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  parent_uuid       TEXT NOT NULL,
  parent_doctype    TEXT NOT NULL,
  parent_fieldname  TEXT NOT NULL,
  local_path        TEXT NOT NULL,
  file_name         TEXT,
  mime_type         TEXT,
  is_private        INTEGER NOT NULL DEFAULT 1,
  size_bytes        INTEGER,
  state             TEXT NOT NULL,                   -- pending|uploading|done|failed
  retry_count       INTEGER NOT NULL DEFAULT 0,
  last_attempt_at   INTEGER,
  error_message     TEXT,
  server_file_name  TEXT,
  server_file_url   TEXT,
  created_at        INTEGER NOT NULL
);
CREATE INDEX ix_attach_state  ON pending_attachments(state);
CREATE INDEX ix_attach_parent ON pending_attachments(parent_uuid, parent_fieldname);

CREATE TABLE sdk_meta (
  schema_version    INTEGER,
  session_user_json TEXT,
  bootstrap_done    INTEGER NOT NULL DEFAULT 0
);
```

### 4.5 Field-type → SQLite column type

| Frappe field | SQLite column | Notes |
|---|---|---|
| Data, Small Text, Long Text, Text, Code, HTML, JSON, Read Only, Password, Color | `TEXT` | |
| Select, Rating (numeric 1–5), Barcode | `TEXT` | options enforced by meta, not constraint |
| Int, Check, Rating | `INTEGER` | Check stored 0/1 |
| Float, Currency, Percent | `REAL` | |
| Date, Datetime, Time | `TEXT` | ISO8601, sortable as string |
| Duration | `INTEGER` | seconds |
| Link | `TEXT` | holds `server_name` OR `mobile_uuid` (disambiguated by `<field>__is_local`) |
| Dynamic Link | `TEXT` | value as-is; target doctype resolved at read time from sibling field |
| Attach, Attach Image | `TEXT` | `file_url` once uploaded, else `pending:<attach_id>` marker |
| Signature | `TEXT` | base64 or file_url |
| Table, Table MultiSelect | — | child table, not a parent column |
| Geolocation | `TEXT` | GeoJSON |
| Button, Column/Section/Tab Break, Heading | — | UI-only, no column |

### 4.6 Auto-indexes

Hard cap **`maxIndexesPerDoctype = 7`** (includes system). Priority fill order:

1. `server_name` (always)
2. `modified` (always)
3. `sync_status` (always)
4. `<title_field>__norm` if title_field is a text type
5. Up to 2 from `search_fields` (their `__norm` columns)
6. Remaining slots: Link fields ordered by dep-graph edge count (most-queried first)

Rebuilt on every `meta_watermark` advance. Consumer can override cap via `SDKConfig(maxIndexesPerDoctype: N)`.

### 4.7 Link field storage — `__is_local` flag

For each Link / Dynamic Link field `<field>`:
```
<field>            TEXT           -- server_name OR mobile_uuid of target
<field>__is_local  INTEGER        -- 1 if value is a local mobile_uuid, 0 if server_name
```
FilterParser auto-appends `AND <field>__is_local=0` when comparing Link fields to server values. UnifiedResolver uses the flag to resolve the target's current `server_name` at read time via `docs__<target>.mobile_uuid`.

Push-time UUID rewrite (section 5.2) strips `__is_local=1` markers: looks up `docs__<target>.server_name` from `mobile_uuid`; if null, fails the push with `BlockedByUpstream`; if found, writes final `server_name` into payload and clears flag.

### 4.8 Search normalization — `__norm` columns

For fields in meta's `search_fields`, `title_field`, or with `search_index=1`:
```
<field>__norm TEXT   (plus ix_<doctype>_<field>_norm index)
```
Populated on every INSERT/UPDATE via `normalizeForSearch(value)`:
```
lowercase → NFKD decompose → strip combining marks → collapse whitespace
```
FilterParser rewrites LIKE queries to use `<field>__norm` and normalizes the query value identically. Equality/range ops use raw column (exact-match semantics preserved).

Consumer may override with `SDKConfig(normalizeForSearch: ...)`.

### 4.9 Migration triggers

- `FrappeSDK.initialize()` and app resume (when `Connectivity.isOnline`): fetch each in-scope doctype's current `modified` via `GET /api/resource/DocType/<X>?fields=["modified"]` and compare against local `meta_watermark`. If different, refetch full meta. (Optional optimization: if the consumer ships a bulk `get_meta_watermarks` endpoint and advertises it via the `X-Mobile-Essentials-Version` response header, SDK batches the check into one request — see §10.)
- If advanced for doctype X: fetch full meta → diff fields → apply:
  - **New field**: `ALTER TABLE docs__X ADD COLUMN <field> <type>` with `NULL` default; if field is Link, also `ADD COLUMN <field>__is_local`; if searchable, also `ADD COLUMN <field>__norm` + backfill `UPDATE … SET <field>__norm = normalizeForSearch(<field>)` in 500-row chunks via `WriteQueue`.
  - **Removed field**: column remains (SQLite < 3.35 cannot `DROP COLUMN` atomically; impact is negligible since unused columns aren't read). Drop the field's index if one existed.
  - **Type changed**: values left as-is; SQLite's loose typing preserves storage, reads cast at query time as needed.
  - **Renamed field**: treated as remove + add; data on that field is lost (accepted limitation; Frappe's meta doesn't track rename mappings).
- Entire migration per doctype wrapped in a single SQLite transaction; on failure, old state preserved and user-visible "migration pending" note can be surfaced.
- SDK-level schema changes between SDK releases use `sdk_meta.schema_version` + numbered migrations.

## 5. Sync engines

### 5.1 PullEngine

**Entry points.** Declared by consumer in `SDKConfig.offlineEntryPoints`. Closure computed via BFS on `{Link, Table, Table MultiSelect}` edges from `doctype_meta.dep_graph_json`. Child doctypes (`is_child_table=1`) are not pulled independently — they arrive nested in their parent rows. No depth cap; system doctypes included if reached.

**Per-doctype pull loop:**

```
cursor ← doctype_meta.last_ok_cursor               -- {modified, name} or null
loop:
    if NOT canPullDoctype(doctype):                -- see 5.4 gating
        mark deferred; break
    acquire pullInFlight[doctype] = true
    scratch ← cursor
    while true:
        page ← GET /api/resource/<doctype>
            filters: modified > scratch.mod
                     OR (modified = scratch.mod AND name > scratch.name)
            order_by: 'modified asc, name asc'
            limit_page_length: 500
            fields: derived from meta (all persisted fields)
        if page empty: break
        parsed ← await compute(jsonParse, page)                 -- isolate
        await WriteQueue[doctype].submit(txn ⇒ applyPage(txn, parsed))
        scratch ← {mod: parsed.last.modified, name: parsed.last.name}
    UPDATE doctype_meta SET last_ok_cursor = scratch, last_pull_ok_at = now
    release pullInFlight[doctype]
```

`applyPage(txn, rows)` — UPSERT by `server_name`, transactional parent+children:

```
for r in rows:
    existing ← txn.select('docs__X').whereServerName(r.name).first()
    if existing and existing.sync_status in (dirty, failed, conflict):
        -- server has advanced but local has unsynced changes → flag for push-time resolution
        txn.update('docs__X').set(sync_status='conflict', sync_error='server_modified=' + r.modified)
            .where(mobile_uuid=existing.mobile_uuid)
        continue
    uuid ← existing.mobile_uuid if existing else newUuid()
    txn.upsert('docs__X', {mobile_uuid: uuid, server_name: r.name,
                           modified: r.modified, sync_status: 'synced',
                           ...r.fields (via meta-mapped columns),
                           ...<field>__is_local=0 for all Link fields (server values),
                           ...<field>__norm=normalizeForSearch(r.<field>) for norm fields})
    for (childfield, childRows) in r.child_tables:
        txn.delete('docs__<child>').where(parent_uuid=uuid, parentfield=childfield)
        for (idx, cr) in enumerate(childRows):
            txn.insert('docs__<child>', {mobile_uuid: newUuid(), server_name: cr.name,
                                         parent_uuid: uuid, parent_doctype: doctype,
                                         parentfield: childfield, idx: idx,
                                         modified: cr.modified, ...cr.fields})
```

Concurrency: multiple doctypes pull in parallel through `PullPool` (2/4/8 device-tier). Pages within one doctype are serial (cursor is inherently ordered). Isolate parse of page N overlaps with GET of page N+1.

**Cursor advance is atomic per full-doctype success.** Mid-pull crash → next run resumes from the persisted cursor, never skipping rows even when many share identical `modified` seconds.

### 5.2 PushEngine

**Driver.** Reads `outbox`. Triggered on: manual `syncNow()`, app resume post-pull, post-save debounced 2s, post-Connectivity-restore.

**Per-run tier computation** (in-memory):

```
pending ← SELECT FROM outbox WHERE state='pending' ORDER BY created_at
-- A row R depends on row R' if R.payload has a Link (or child-Link) field where
--   __is_local=1 and its target's mobile_uuid equals R'.mobile_uuid AND R'.operation=INSERT.
-- Tier 0 = rows with no pending dependencies.
-- Tier k = rows whose dependencies are in tiers < k.
```

**Dispatch:**

```
for tier in tiers:
    await Future.wait(
        tier.map(row ⇒ PushPool.submit(() ⇒ processOutboxRow(row)))
    )
    -- any failures in this tier → mark downstream dependents in later tiers
    --   as state='blocked' BEFORE dispatching the next tier
    markBlocked(failures_in_this_tier)
```

**`processOutboxRow(row)`:**

```
await WriteQueue[row.doctype].submit(txn ⇒
    txn.update('outbox').set(state='in_flight', last_attempt_at=now).where(id=row.id))

try:
    payload ← assemble(row)     -- see below
    response ← await httpForOp(row.operation, row.doctype, payload, row.server_name)

    await WriteQueue[row.doctype].submit(txn ⇒ writeBackResponse(txn, row, response))

except TimestampMismatchError:
    if row.retry_count < 1:
        server_snapshot ← await GET /api/resource/<doctype>/<server_name>
        merged ← threeWayMerge(row.snapshot_modified, docs__X, server_snapshot)
        await WriteQueue[row.doctype].submit(txn ⇒ {
            txn.update('docs__X').set(...merged, modified=server_snapshot.modified)
            txn.update('outbox').set(payload=merged, retry_count=row.retry_count+1, state='pending')
        })
    else:
        markConflict(row, "conflict persists after 1 auto-retry")
        -- UI surfaces explicit user choice: pullAndOverwriteLocal | keepLocalAndRetry

except LinkExistsError as e:        -- on DELETE
    markFailed(row, 'LINK_EXISTS', structured={linked:{doctype:[names]}})
    -- UI surfaces DeleteCascadePrompt

except BlockedByUpstream as e:
    markBlocked(row, reason=e)

except (NetworkError, TimeoutError) as e:
    if row.retry_count < 3:
        schedule retry with backoff 2s, 5s, 10s
    else:
        markFailed(row, 'NETWORK', e.message)

except (PermissionDenied, ValidationError, MandatoryError) as e:
    markFailed(row, e.code, e.message)
    -- no auto-retry; needs user fix
```

**`assemble(row)`:**

1. Read latest `docs__<doctype>` row by `mobile_uuid` (authoritative snapshot).
2. Read child rows from `docs__<child>` tables where `parent_uuid=row.mobile_uuid`, ordered by `idx`, nested under their `parentfield`.
3. UUID→server-name rewrite: for every Link field (parent and child) where `__is_local=1`, look up `docs__<target>.server_name` by `mobile_uuid`. If null → raise `BlockedByUpstream(field, target_uuid)`.
4. Inline attachment file_urls: for every field where value matches `pending:<attach_id>`, read `pending_attachments` row; if `state='done'`, replace with `server_file_url`. If `state` is other → run attachment sub-pipeline (5.3); if uploads succeed, retry this assemble; else raise `BlockedByUpstream`.
5. Include `mobile_uuid` in payload (server-side dedup hook reads it).
6. For UPDATE: include `modified` from the snapshot we hold (Frappe's `check_if_latest` uses it).
7. Strip `__is_local`, `__norm`, and system columns (`sync_status`, `sync_error`, etc.) — send only Frappe-facing fields + `mobile_uuid` + nested children.

**Op → HTTP method mapping:**

| Outbox operation | HTTP | Endpoint |
|---|---|---|
| INSERT | `POST` | `/api/resource/<doctype>` |
| UPDATE | `PUT` | `/api/resource/<doctype>/<server_name>` |
| SUBMIT | `POST` | `/api/method/frappe.client.submit` (payload: full doc dict) |
| CANCEL | `POST` | `/api/method/frappe.client.cancel` (`doctype`, `name`) |
| DELETE | `DELETE` | `/api/resource/<doctype>/<server_name>` |

**Response write-back:**

```
writeBackResponse(txn, row, resp):
    txn.update('docs__<parent>').set(
        server_name=resp.name, modified=resp.modified, sync_status='synced',
        sync_error=null, sync_attempts=0
    ).where(mobile_uuid=row.mobile_uuid)
    for (childfield, childList) in resp.child_tables:
        for cr in childList:
            txn.update('docs__<child>').set(server_name=cr.name, modified=cr.modified)
                .where(parent_uuid=row.mobile_uuid, parentfield=childfield, idx=cr.idx)
    txn.update('outbox').set(state='done', server_name=resp.name).where(id=row.id)
```

**Collapsing on enqueue.** When a write targets a `mobile_uuid` that already has an outbox row in `state IN (pending, blocked, failed)` with `operation=INSERT`: update that row's `payload` in place and reset `state='pending'`. Same for UPDATE/UPDATE. SUBMIT/CANCEL/DELETE never collapse — they're discrete transitions.

**Resume-safe restart.** On SDK startup: `UPDATE outbox SET state='pending' WHERE state='in_flight'`. Unfinished attempts retried.

**Retention.** `done` rows pruned after 24 h. `failed`/`conflict` rows retained until user retries or force-logout.

**Outbox state machine:**

```
pending ──dispatch──▶ in_flight ──success──▶ done
                           │
                           ├──network + retries──▶ failed
                           ├──TimestampMismatch persists──▶ conflict
                           ├──LinkExists──▶ failed (structured)
                           └──BlockedByUpstream──▶ blocked
                                                     │
                                 (user retry OR upstream ok) ──▶ pending
```

**`docs__<doctype>.sync_status` ↔ `outbox.state` correspondence:**

| `docs__<doctype>.sync_status` | Related `outbox.state` for the latest row of this mobile_uuid | When it's set |
|---|---|---|
| `dirty` | `pending` or `in_flight` | User save produced a write; outbox row enqueued (or picked up) |
| `synced` | `done` (or no outbox row) | Push completed successfully and wrote-back |
| `failed` | `failed` | Push exhausted retries or rejected by server |
| `conflict` | `conflict` | TimestampMismatch auto-retry exhausted, OR pull saw server-advanced row while local was dirty/failed |
| `blocked` | `blocked` | Upstream doc not yet synced, or attachment upload failed |

The two stay synchronized: `WriteQueue[doctype].submit(...)` updates both in the same transaction whenever an outbox row changes state. UI reads `sync_status` directly from the parent table (indexed), while the outbox is the source of truth for retry metadata and the op queue.

### 5.3 Attachment sub-pipeline

Runs as a prerequisite stage for any outbox row whose assembled payload references `pending:<attach_id>`.

```
for each pending_attachments p with state='pending' for this parent:
    UPDATE pending_attachments SET state='uploading' WHERE id=p.id
    try:
        resp ← POST /api/method/upload_file multipart,
                    file=p.local_path,
                    dt=doctype, dn='new-' + doctype_snake_case,   -- placeholder ok
                    is_private=p.is_private
        UPDATE pending_attachments SET state='done',
                                       server_file_name=resp.name,
                                       server_file_url=resp.file_url
            WHERE id=p.id
    except (NetworkError, TimeoutError):
        if p.retry_count < 3: backoff 2s/5s/10s, retry
        else: UPDATE pending_attachments SET state='failed', error_message=...
              markBlocked(outbox_row, 'attachment failed — user must reattach')
    except ServerError:
        UPDATE pending_attachments SET state='failed'
        markBlocked(outbox_row, ...)
```

After all attachments for a parent are `done`: inline `server_file_url` into payload, proceed with parent push. Failed final → parent outbox row stays `blocked` (policy 7d(α)); user reattaches to retry.

Cap optional on client side via `SDKConfig(maxAttachmentBytes: 104_857_600)` (100 MB). Default = no client cap; relies on Frappe site limit.

### 5.4 Pull/push coordination — per-doctype gate

**Rule.** Pull of doctype X is deferred if `outbox` has any row for X in `state IN (pending, in_flight)`. Push always wins when both want to run.

**Rationale.** Prevents race where pull imports old server state while push of newer local edits is mid-flight — avoids spurious `conflict` flagging of dirty rows that will shortly succeed.

**Implementation:**

```
def canPullDoctype(X):
    return not EXISTS(SELECT 1 FROM outbox
                      WHERE doctype=X AND state IN ('pending', 'in_flight') LIMIT 1)
```

PullEngine checks before each doctype's pull loop. Push waits briefly (≤30 s) for `pullInFlight[X]` to clear; if timeout, re-queues `state='pending'` — picks up next cycle.

**Re-evaluation cadence.** Deferred doctypes re-checked after each push drain, on Connectivity restore, on app resume. Never starved.

**Failed/conflict rows don't block pulls.** A doctype with `failed` outbox rows can still pull; pull's UPSERT preserves local dirty payload per 5.1 `applyPage` rule.

### 5.5 Conflict handling — explicit recap

- **Detected in pull:** UPSERT sees `sync_status IN (dirty, failed, conflict)` + server `modified` advanced → flip row to `conflict`, preserve local payload, do NOT overwrite. Push engine handles.
- **Detected in push:** `TimestampMismatchError` on UPDATE → auto-refetch → three-way merge (base = row.snapshot_modified; ours = `docs__X`; theirs = server snapshot) → retry once.
- **Merge policy:** Field-level last-write-wins favoring fields mutated locally since last pull. For child tables: if parent `sync_status='dirty'`, local list is authoritative.
- **Auto-resolution persistent failure:** state=`conflict`; UI surfaces two choices:
  - `Pull latest and overwrite local` — downloads server snapshot, replaces local, marks outbox `done`, local edits lost (warned).
  - `Keep local and force retry` — refetches server's current `modified`, re-sends local payload with new `modified`, server accepts.

### 5.6 Connectivity & resume

- `ConnectivityWatcher` exposes `Stream<bool>` (`connectivity_plus`).
- In-flight HTTP cancelled on disconnect via `http.Client.close()`.
- `in_flight` outbox rows flipped back to `pending` on reconnect or SDK restart.
- Cursor persisted only on full-doctype success → no data loss on mid-pull disconnect.
- On reconnect: drain deferred pulls; run outbox.

### 5.7 Idempotency

**INSERT is not natively idempotent in Frappe.** Retries can duplicate on flaky networks. Three mitigation layers, priority order — SDK applies the first one available:

**L1. User-set naming (`autoname = field:mobile_uuid`) — recommended, zero overhead.**
If a DocType is configured so that `name = mobile_uuid`, the server `name` is deterministically set to the client-generated UUID. A retried POST with the same name returns `DuplicateEntryError`; SDK catches it, fetches the existing doc, and writes back `name` + `modified` as if the retry had succeeded. No extra round-trip. Every outbox INSERT payload still carries `mobile_uuid` as a data field (not just as the name) for clarity and for L2/L3 compatibility.

**L2. Server `before_insert` dedup hook — consumer opt-in, zero-retry-duplication guarantee.**
Consumer installs a server-side hook in their own Frappe app:
```python
# <consumer_app>/hooks.py
doc_events = {
  "*": {"before_insert": "<consumer_app>.utils.mobile_dedup"}
}

# <consumer_app>/utils.py
def mobile_dedup(doc, method):
    uuid = doc.get('mobile_uuid')
    if not uuid: return
    existing = frappe.db.get_value(doc.doctype, {'mobile_uuid': uuid}, 'name')
    if existing:
        raise frappe.DuplicateEntryError(doc.doctype, existing)
```
(Consumer adds a `mobile_uuid` field to the DocTypes they care about.) SDK treats `DuplicateEntryError` on INSERT the same as L1: fetch existing, write-back. Works alongside L1 or independently.

**L3. Client-side pre-retry GET check — works against stock Frappe, no server changes.**
On network-class failure (timeout, 5xx) during INSERT, SDK does not retry blindly. Before retry it issues:
```
GET /api/resource/<doctype>?filters=[["mobile_uuid","=",<uuid>]]&fields=["name","modified"]&limit_page_length=1
```
If a row comes back, SDK treats the prior POST as succeeded (writes back `name` + `modified`, marks outbox `done`, no retry). Costs one extra round-trip on retries only. Requires the consumer's DocType to have a queryable `mobile_uuid` field (consumer must add this — it's a 1-field schema change, no code).

**Default SDK policy.** At INSERT time SDK inspects meta:
- If `meta.autoname == 'field:mobile_uuid'` → L1 path.
- Else if consumer has advertised `X-Mobile-Essentials-Version` header on login (indicating L2 hook present) → payload still includes `mobile_uuid`; SDK catches `DuplicateEntryError` the same way.
- Else → L3 path on retries.

If neither `mobile_uuid` field is queryable nor autoname uses it (stock DocType, no consumer prep), SDK emits a one-time `InitWarning` at app launch listing affected DocTypes and documents the duplication risk — the onus is on the consumer to choose a mitigation.

**UPDATE** — idempotent via Frappe's native `check_if_latest` (client sends snapshot `modified`).
**SUBMIT / CANCEL** — Frappe raises specific errors ("already submitted" / "already cancelled") that SDK catches as success.
**DELETE** — 404 on a retry treated as success.

## 6. Unified read resolver + FilterParser

### 6.1 Single method

All offline reads — `OfflineRepository.query`, Link picker, `fetch_from`, list screens, direct consumer queries — funnel through:

```dart
class UnifiedResolver {
  Future<QueryResult<Map<String, dynamic>>> resolve({
    required String doctype,
    List<List> filters = const [],
    List<List> orFilters = const [],
    String? orderBy,
    int page = 0,
    int pageSize = 50,
    bool includeFailed = false,
  });
}
```

### 6.2 Flow

```
1. DB read immediately via FilterParser.toSql(...) → SELECT … FROM docs__X LIMIT pageSize OFFSET …
2. Apply precedence rule:
     rows grouped by identity = server_name ?? mobile_uuid
     for each group:
         if any row in (dirty, blocked, conflict) → use it, tag origin=local
         elif synced row → use it, tag origin=server
         failed → excluded unless includeFailed=true
3. Decorate: resolve Link display values (lookup docs__<target>), title per meta.title_field
4. If online: fire background API refresh, deduplicated by requestKey; UPSERTs fresh rows
5. Return QueryResult
```

DB is the single source of truth at read time. Background refresh updates DB as a side effect.

### 6.3 Dedup + debounce

**In-flight dedup** (inside UnifiedResolver):
```
requestKey = sha1(doctype + serializedFilters + orderBy + page)
inflight[key] reused across callers; completion removes key
```

**Caller-side debounce** (SDK-provided widgets): 350 ms on typeahead. Cancel-older policy: each new keystroke's fire cancels the previous background fetch via `CancelToken` + `http.Client.close()`.

**Background-fetch rate cap per doctype**: ≤2 concurrent refreshes (routed through `PullPool`).

### 6.4 FilterParser — operator mapping

All column identifiers validated against `doctype_meta.meta_json` whitelist; unknown → `FilterParseError`. Operators matched against fixed enum. Every value parameter-bound. No string concatenation.

| Op | SQL with null-parity |
|---|---|
| `=`, `!=` on TEXT | `IFNULL(col, '') = ?` / `IFNULL(col, '') != ?` |
| `=`, `!=` on Int/Check/Float | `IFNULL(col, 0) = ?` / `IFNULL(col, 0) != ?` |
| `<`, `<=`, `>`, `>=` | `col <op> ?` |
| `in` (non-empty) | `col IN (?, ?, …)` |
| `in` (empty list) | `1=0` short-circuit |
| `not in` (non-empty) | `col NOT IN (?, …)` |
| `not in` (empty list) | `1=1` |
| `like` / `not like` on norm-column | `IFNULL(<field>__norm, '') LIKE ?` with `normalizeForSearch(query)` |
| `like` / `not like` on raw | `IFNULL(col, '') LIKE ?` (known gap: non-ASCII case) |
| `between` on Date | `col >= ? AND col <= ?` |
| `between` on Datetime | `col >= ? AND col <= ?`; end expanded to 23:59:59 if date-only passed |
| `is set` | `IFNULL(col, '') != ''` |
| `is not set` | `IFNULL(col, '') = ''` |
| `timespan` | resolved via `FrappeTimespan.resolve(value)` → `between` |

**`FrappeTimespan`** supports: `today`, `yesterday`, `tomorrow`, `this week`, `this month`, `this quarter`, `this year`, `last week/month/quarter/year`, `next week/month/quarter/year`, `last N days` (regex-parsed N).

**Link field filters** — parser auto-appends `AND <field>__is_local=0` when comparing to server-known values.

**AND + OR combination:**
```
WHERE (and_filter_1) AND (and_filter_2) … AND (or_filter_1 OR or_filter_2 …)
```

**Out of scope (throw `UnsupportedFilterError`):** cross-doctype child filters, tree operators, dynamic values like `user.department`.

### 6.5 Known gaps (documented)

- **Non-ASCII LIKE**: mitigated by `__norm` columns for search-indexed fields; raw columns unchanged. Consumer can override normalizer.
- **Dynamic values**: caller pre-resolves from `SessionUser`.
- **Per-record `user_permissions`**: local results bounded by last-pull state; revocation propagates only on next pull.
- **Tree ops**: require `lft`/`rgt` caching; not in v1.

### 6.6 SessionUser

```dart
class SessionUser {
  final String name;              // user email (Frappe User PK)
  final String? fullName;
  final String? userImage;
  final String? language;
  final String? timeZone;
  final List<String> roles;
  final Map<String, List<String>> permissions;       // doctype → ops
  final Map<String, String> userDefaults;
  final Map<String, dynamic> extras;
}
```
Populated on login, refreshed after first meta pull per session. Exposed: `FrappeSDK.instance.sessionUser` + `.sessionUser$`. Persisted in `sdk_meta.session_user_json`. Cleared on logout (atomic wipe).

## 7. UI surface and lifecycle

### 7.1 SyncState — composable

```dart
class SyncState {
  final bool isOnline;
  final bool isInitialSync;
  final bool isPulling;                       // ≥1 doctype pulling
  final bool isPushing;                       // ≥1 outbox row in_flight
  final bool isUploading;                     // ≥1 pending_attachment uploading
  final bool isPaused;
  final Map<String, DoctypeSyncState> perDoctype;
  final QueueSummary queue;
  final SyncError? lastError;
  final DateTime? lastSyncAt;
}
class DoctypeSyncState {
  final int pulledCount;
  final int? lastPageSize;
  final bool hasMore;                         // lastPageSize == 500 → likely more
  final bool deferred;
  final Cursor? lastOkCursor;
  final String? note;
  final DateTime? startedAt;
  final DateTime? completedAt;
}
```

No single "phase" enum — activities overlap freely. `SyncStatusBar` picks a priority label: Offline > Paused > Initial sync > Pushing > Uploading > Pulling > hidden.

Real-total progress (`42 of 500`) is opt-in via `SDKConfig(fetchCountBeforePull: true)` — costs one extra `get_count` RTT per doctype. Default shows honest progress: `Pulling SEDVR… 1,240 so far`.

### 7.2 Default widgets (replaceable)

- **`SyncStatusBar`** — top strip; hidden when idle+online.
- **`DocumentListFilterChip`** — tri-state `All | Unsynced | Errors` in list-screen app bar.
- **`SyncErrorsScreen`** — grouped by doctype, per-row actions: `Retry`, `View error`, `Open`. Header: `Retry all` with priority ordering (7.4) + live progress + `Stop`.
- **`SyncProgressScreen`** — blocking initial-sync progress, `Pause` persists cursors; `Cancel` → logout+wipe confirmation.
- **`LogoutGuardDialog`** — `Sync now` / `Log out anyway` / `Cancel`.
- **`ForceLogoutConfirm`** — per-doctype unsynced counts; user types `LOGOUT` to confirm.
- **`DeleteCascadePrompt`** — on `LINK_EXISTS` failure; shows linked docs per doctype with counts. `Delete all` enqueues DELETE outbox rows for every dependent with `created_at` strictly earlier than the original parent's DELETE row, so tier computation dispatches dependents first and the parent's DELETE is retried last (otherwise it would hit the same `LINK_EXISTS`). `Fix manually` navigates to errors screen.

All widgets subscribe to `syncState$`. Consumer can disable SDK widgets entirely via `SDKConfig(showSDKWidgets: false)` and build their own on the same stream.

### 7.3 Initial sync lifecycle

```
Login success
  → SessionUser populated from login response
  → if sdk_meta.bootstrap_done = 0:
        push SyncProgressScreen (blocking route)
        PullEngine runs full closure
        on complete: bootstrap_done=1, pop screen
     else:
        proceed to app home
```

App resume: if online AND last pull > 60 s ago → fire incremental pull in background. Paused bootstrap → re-present blocking screen, resume from cursors.

### 7.4 Retry-all priority

When user triggers `Retry all`, outbox rows are re-queued in priority order (1 highest). Priority keyed on `(state, error_code)`:

| # | Match | Rationale |
|---|---|---|
| 1 | `state=failed` AND `error_code IN (NETWORK, TIMEOUT)` | Transient; network is back now |
| 2 | `state=blocked` (any error_code) | Releases dependents on parent success |
| 3 | `state=conflict` | Often succeeds after auto-merge retry |
| 4 | `state=failed` AND `error_code=LINK_EXISTS` | Succeeds only if dependents now deleted |
| 5 | `state=failed` AND `error_code IN (VALIDATION, MANDATORY)` | Usually requires user fix |
| 6 | `state=failed` AND `error_code=PERMISSION_DENIED` | Requires role change |
| 7 | `state=failed` AND `error_code IN (UNKNOWN, null)` | Last |

Within each priority bucket: topological tier order (dependencies before dependents), then `created_at`. Per-doc `Retry` buttons disabled during `Retry all`; header shows live `Retrying 23… 8 succeeded, 2 failed, 13 pending` + `Stop`.

### 7.5 Atomic logout wipe

```
SDK.logout():
  1. cancel in-flight HTTP (http.Client.close())
  2. SessionUser=null; sessionUser$.emit(null)
  3. server logout (fire-and-forget, 2s timeout)
  4. clear secure storage (tokens, credentials)
  5. close DB; delete DB file (+ -wal, -shm); reopen empty DB
  6. navigate to login
```

File-level delete is atomic at the OS. Half-wiped state impossible.

## 8. Concurrency utilities

- **`ConcurrencyPool`** — FIFO bounded-parallel for HTTP. Two instances: `PullPool`, `PushPool`. Sized by `DeviceTier`: RAM ≤3 GB or cores ≤4 → 2; RAM ≤6 GB or cores ≤6 → 4; else 8. Override via `SDKConfig(concurrencyOverride: N)`.
- **`WriteQueue`** — per-doctype single-slot queue; batches consecutive submits into one SQLite transaction every 50 rows or 250 ms. Eliminates SQLite write contention. Different doctypes write in parallel.
- **`IsolateParser`** — `compute()` wrapper for JSON pages > 100 KB.
- **`ConnectivityWatcher`** — `connectivity_plus` wrapper exposing `isOnline$` stream; drains deferred pulls on restore.

## 9. Public SDK API (additions)

### 9.1 `FrappeSDK` (extended)

```dart
class FrappeSDK {
  static FrappeSDK get instance;
  // existing: auth, client, meta, forms — unchanged
  OfflineRepository get offline;
  SyncController     get sync;
  SessionUser?       get sessionUser;
  Stream<SessionUser?> get sessionUser$;
  ConnectivityWatcher get connectivity;
}
```

### 9.2 `OfflineRepository`

```dart
abstract class OfflineRepository {
  Future<QueryResult<Map<String, dynamic>>> query({
    required String doctype,
    List<List> filters = const [],
    List<List> orFilters = const [],
    String? orderBy,
    int page = 0,
    int pageSize = 50,
    bool includeFailed = false,
  });

  Future<Map<String, dynamic>?> get(String doctype, String nameOrUuid);

  Future<String> save(String doctype, Map<String, dynamic> data);     // returns mobile_uuid
  Future<void>   submit(String doctype, String mobileUuid);
  Future<void>   cancel(String doctype, String mobileUuid);
  Future<void>   delete(String doctype, String mobileUuid);

  Future<String> queueAttachment({
    required String parentDoctype,
    required String parentUuid,
    required String parentFieldname,
    required File file,
    bool isPrivate = true,
  });

  Stream<List<Map<String, dynamic>>> watch({
    required String doctype,
    List<List> filters = const [],
    int pageSize = 50,
  });
}
```

### 9.3 `SyncController`

```dart
abstract class SyncController {
  SyncState get state;
  Stream<SyncState> get state$;

  Future<void> syncNow();
  Future<void> pause();
  Future<void> resume();
  Future<void> cancelInitialSync();

  Future<void> retry(int outboxId);
  Future<void> retryAll({List<String>? filterDoctypes});
  Future<void> resolveConflict({
    required int outboxId,
    required ConflictAction action,             // pullAndOverwriteLocal | keepLocalAndRetry
  });

  Future<List<OutboxRow>> pendingErrors();
  Future<DeleteCascadePlan> previewDeleteCascade(int outboxId);
  Future<void> acceptDeleteCascade(int outboxId);
}
```

### 9.4 Public types

```dart
class QueryResult<T> {
  final List<T> rows;
  final bool hasMore;                 // lastPageSize == pageSize
  final int returnedCount;            // rows.length
  final Map<RowOrigin, int> originBreakdown;   // {local: n, server: m}
}

enum RowOrigin { local, server }

class Cursor {
  final String? modified;             // ISO8601 from server
  final String? name;                 // last name in page
}

enum ConflictAction {
  pullAndOverwriteLocal,              // download server snapshot, overwrite local
  keepLocalAndRetry,                  // refetch modified, re-send local payload
}

class OutboxRow {
  final int id;
  final String doctype;
  final String mobileUuid;
  final String? serverName;
  final OutboxOperation operation;    // insert|update|submit|cancel|delete
  final OutboxState state;            // pending|inFlight|done|failed|conflict|blocked
  final int retryCount;
  final DateTime? lastAttemptAt;
  final String? errorMessage;
  final ErrorCode? errorCode;         // NETWORK|TIMEOUT|TIMESTAMP_MISMATCH|
                                      // LINK_EXISTS|PERMISSION_DENIED|
                                      // VALIDATION|MANDATORY|UNKNOWN
  final DateTime createdAt;
}

class DeleteCascadePlan {
  final String rootDoctype;
  final String rootMobileUuid;
  final Map<String, List<String>> blockedBy;   // doctype → server names blocking the delete
  final int totalDependents;
}

class SyncError {
  final String doctype;
  final String mobileUuid;
  final OutboxOperation operation;
  final ErrorCode code;
  final String message;
  final DateTime at;
}
```

### 9.5 `SDKConfig`

```dart
class SDKConfig {
  // existing fields preserved

  final List<String> offlineEntryPoints;            // consumer-declared
  final int? concurrencyOverride;                   // null = auto device-tier
  final int maxIndexesPerDoctype;                   // default 7
  final Duration pullThrottle;                      // default 60s
  final bool fetchCountBeforePull;                  // default false
  final String Function(String)? normalizeForSearch;
  final bool showSDKWidgets;                        // default true
  final int? maxAttachmentBytes;                    // null = no client cap
  final IdempotencyStrategy? idempotencyOverride;   // null = auto-detect (L1→L2→L3)
}
enum IdempotencyStrategy { userSetNaming, serverDedupHook, preRetryGetCheck }
```

## 10. Server requirements

SDK targets **stock Frappe v15+** with no proprietary server app required. Standard endpoints only.

### 10.1 Required (stock Frappe v15+)

| Endpoint | Purpose |
|---|---|
| `POST /api/method/login` OR API-key/secret auth OR OAuth token | Session establishment |
| `GET /api/resource/<doctype>` | List + cursor pagination (supports `filters`, `fields`, `order_by`, `limit_page_length`, `limit_start`) |
| `GET /api/resource/<doctype>/<name>` | Single doc |
| `POST /api/resource/<doctype>` | Insert |
| `PUT /api/resource/<doctype>/<name>` | Partial update |
| `DELETE /api/resource/<doctype>/<name>` | Delete |
| `POST /api/method/frappe.client.submit` | Submit |
| `POST /api/method/frappe.client.cancel` | Cancel |
| `POST /api/method/upload_file` | Attachment upload |
| `GET /api/resource/DocType/<doctype>?fields=["modified"]` | Meta-change detection (compare `modified` vs local `meta_watermark`) |
| `GET /api/resource/DocType/<doctype>` | Full meta (fetched on change) |

Insert response must include `name` + all child rows with their `name` + `modified` — this is native Frappe behavior, called out so consumer doesn't accidentally override with a custom handler that strips it.

### 10.2 Optional consumer server app (recommended for scale)

The consumer may ship a small helper Frappe app to reduce round-trips and strengthen idempotency. SDK auto-detects it via an `X-Mobile-Essentials-Version` response header on login.

| Capability | Endpoint / hook | Benefit |
|---|---|---|
| Bulk meta watermark | `GET /api/method/<app>.get_meta_watermarks?doctypes=[…]` → `[{doctype, modified}]` | One request instead of N to check all doctypes' metas |
| `before_insert` dedup hook | `doc_events['*']['before_insert']` (see §5.7 L2) | Eliminates INSERT-retry duplication without requiring `autoname=field:mobile_uuid` |
| `SessionUser` payload on login | Custom `login` response body extension | Populates `SessionUser` in one trip instead of follow-up calls |
| `mobile_uuid` custom field on DocTypes via fixtures | DocField `mobile_uuid` (Data, unique, hidden) | Makes L3 GET-check fast and guarantees duplication detection |

**SDK never refuses to initialize if these are absent.** Without them, SDK falls back to the stock endpoints + L3 pre-retry GET idempotency (see §5.7). The consumer app is a performance and correctness *upgrade*, not a gate.

### 10.3 What SDK does if nothing is done server-side

SDK works against a vanilla Frappe instance with zero customization. Consequences the consumer accepts:
- Meta watermark check uses N per-doctype GETs instead of one bulk call (N small for typical apps; one-time at resume).
- INSERT idempotency falls back to L3 (extra GET on retries only) and requires the consumer to either (a) use `autoname=field:mobile_uuid` on mobile-created DocTypes, or (b) add a `mobile_uuid` custom field for L3 to query against. If neither is done, the SDK emits an `InitWarning` per affected DocType and duplicates may occur on network-error retries.
- `SessionUser.permissions` populated by a follow-up `GET /api/method/frappe.client.get_list?doctype=User&filters=[["name","=",<me>]]` + `GET /api/method/frappe.client.get_value?doctype=User&fieldname=roles&filters=…`.

## 11. Testing

### 11.1 Unit
- `FilterParser` — every operator, null-parity rules, OR+AND combinations, column whitelist, injection-attempt rejection.
- `FrappeTimespan` — every keyword vs. fixed reference dates.
- `DependencyGraphBuilder` — synthetic metas (linear, branching, cycles → error, child rides with parent).
- `normalizeForSearch` — Latin accents, Devanagari, ASCII case.
- `OutboxCollapser` — INSERT+UPDATE collapse; never-collapse for SUBMIT/CANCEL/DELETE; retention pruning.

### 11.2 Integration (in-memory sqflite + mocked FrappeClient)
- `PullEngine`: first sync, incremental, resume-from-crash mid-page, conflict detection, parent+children atomic replace rollback, pull-defer when outbox active.
- `PushEngine`: tier ordering, UUID rewrite at send, `mobile_uuid` dedup roundtrip, TimestampMismatch auto-merge, LinkExists cascade, blocked-by-upstream, priority-ordered retry-all.
- `AttachmentPipeline`: upload-first-then-parent, failure blocks parent, backoff sequence.
- Migration: add field, remove field (column stays), type change (values as-is), meta-watermark trigger.

### 11.3 Widget / e2e (optional, in example app)
- `SyncStatusBar` priority label across overlapping flags.
- `LogoutGuardDialog` counts match outbox + pending_attachments; `LOGOUT` typed confirm.
- `SyncProgressScreen` pause/resume.
- `SyncErrorsScreen` retry-all priority.

### 11.4 Gates
- P1: existing v1.1.0 consumer apps continue to work after migration.
- P3: 10 k-row doctype initial sync on 2 GB / 4-core emulator < 5 min, no UI jank (frame build time < 16 ms p95 on the UI isolate during sync).
- P4 (revised — realistic for low-end Android):
  - `max_inflight_network` honored: no more than `PushPool.size` (2/4/8 by tier) HTTP requests in flight at once.
  - `max_db_writes_per_doctype = 1`: WriteQueue per-doctype serialization verified under stress.
  - `batch_size = 20–50`: per-transaction write grouping stays within this range.
  - **Throughput test:** 500 queued offline saves (enqueued at human-plausible pace: ~10/sec from the UI simulation) drain to a mock server with **0 duplicates**, **0 SQLite lock errors**, and **peak memory delta < 50 MB** on a 2 GB emulator. Queue drain time measured and reported; no hard deadline — we measure vs. optimize, not vs. fail.
  - **Resilience test:** pull app kill mid-drain at 50 %, relaunch, confirm remaining 250 saves complete with same 0-duplicate guarantee (tests outbox resume + L2/L3 dedup).
- P5: all existing form + list screens work offline identically to online.
- P6: SDK minor-version bump + changelog shipped.

## 12. Phasing

Six independently mergeable plans. Dependencies: P2 ← P1; P3 ← P2; P4 ← P1+P2; P5 ← P3+P4; P6 ← P5.

| # | Phase | Scope |
|---|---|---|
| P1 | Schema foundation + outbox + idempotency strategy | Per-doctype + per-child tables; outbox; pending_attachments; doctype_meta with dep_graph; one-time migration from current single `documents` table preserving existing dirty rows; auto-detect idempotency strategy per DocType (L1/L2/L3 per §5.7) — no server-app requirement |
| P2 | Meta service + dependency graph | Closure builder; dep-graph cache; meta-watermark migration engine; `__norm` column population |
| P3 | Pull engine + concurrency utilities | `PullPool`, `WriteQueue`, cursor-based watermark, isolate parse, pull/push coordination gate, `syncState$` stream |
| P4 | Push engine + conflict + attachments | `PushPool`, tier dispatch, UUID rewrite, TimestampMismatch auto-merge, attachment sub-pipeline, outbox state machine, retry-all priority |
| P5 | Unified read resolver + FilterParser | `UnifiedResolver`, dedup + debounce, FilterParser with all operators + null-parity, rewire Link picker + `fetch_from` + list screens |
| P6 | UI surface + lifecycle | All default widgets, `SessionUser` hooks, atomic wipe, consumer theming/copy overrides |

Each phase gets: design reference, implementation, tests to the specified tier, user-facing docs, changelog, migration-guide snippet.

### 12.1 v1.1.0 → v2 data migration (inside P1)

Current SDK ships a single `documents` table at `lib/src/database/app_database.dart:135`: `(localId, doctype, serverId, dataJson, status, modified)`. Any consumer app that adopted v1.1.0 may have dirty rows on device that must survive the schema change.

**Preconditions.** The device must have network connectivity on first launch after upgrade to fetch each affected DocType's meta (via `GET /api/resource/DocType/<X>`) — metas are required to map JSON blobs into per-doctype columns. If offline on first launch after upgrade, the migration blocks app entry with a `MigrationBlockedScreen` that retries on Connectivity restore — same blocking pattern as `SyncProgressScreen`.

**Algorithm (run once, guarded by `sdk_meta.schema_version < 2`):**

```
BEGIN TRANSACTION  (per doctype, not one mega-txn; see below)
  1. distinct_doctypes ← SELECT DISTINCT doctype FROM documents
  2. For each doctype X in distinct_doctypes:
       fetch meta via MetaService (required, networked)
       IF meta unavailable (404 — doctype renamed/removed on server):
         move rows to documents__orphaned_v1 (stash table), log + surface counter
         in a post-migration advisory screen; skip to next doctype
       create docs__X + per-child docs__<child> tables with full v2 schema
       populate doctype_meta row (meta_json, table_name, is_entry_point,
         is_child_table, etc.)

  3. For each row r in documents WHERE doctype=X (chunked via WriteQueue[X] 500 at a time):
       parsed ← JSON.decode(r.dataJson)
       split parsed into (parent_fields, child_table_payloads) per meta

       INSERT INTO docs__X (
         mobile_uuid  = r.localId,          -- preserve existing local identity
         server_name  = r.serverId,         -- null if it was only ever local
         sync_status  = 'dirty' IF r.status='dirty' ELSE 'synced',
         docstatus    = parsed.docstatus || 0,
         modified     = r.modified,
         local_modified = now,
         pulled_at    = CASE WHEN r.status='clean' THEN r.modified ELSE NULL END,
         … per-field columns per 4.5 mapping,
         <field>__is_local = 0 for all Link values
           (we assume pre-v2 Link values were server_names — the old code path
            only wrote them after server round-trip;
            if that assumption is wrong we cannot detect it retroactively,
            accepted migration risk — documented in changelog)
         <field>__norm  = normalizeForSearch(<field>) for norm fields
       )

       For each (childfield, child_rows) in child_table_payloads:
         INSERT INTO docs__<child> (
           mobile_uuid, server_name, parent_uuid=r.localId,
           parent_doctype=X, parentfield=childfield, idx, modified, …fields
         )

       IF r.status='dirty':
         INSERT INTO outbox (
           doctype=X, mobile_uuid=r.localId,
           server_name=r.serverId,
           operation = CASE WHEN r.serverId IS NULL THEN 'INSERT' ELSE 'UPDATE' END,
           payload   = JSON of parsed (for replay),
           state     = 'pending',
           created_at = r.modified        -- preserve original save order
         )
COMMIT  (per-doctype)

  4. After all doctypes migrated:
       UPDATE sdk_meta SET schema_version = 2
       RENAME TABLE documents TO documents__archived_v1      -- do not drop;
         keep for 1 SDK version as an audit/rollback aid; next major release drops it.
       (Orphaned rows remain in documents__orphaned_v1 indefinitely until
        user confirms loss via advisory screen.)
```

**Edge cases explicitly handled:**
- Concurrent user action during migration: not possible — migration runs before app surfaces any UI (on the MigrationBlockedScreen).
- Row with `docstatus > 0` and `status='dirty'`: enqueue both an UPDATE (to flush field edits) and a SUBMIT outbox row if the local payload has `docstatus=1` but server's last-known `docstatus` was 0. Deterministic rule: compare `parsed.docstatus` vs existing dump's docstatus; if raised, append SUBMIT; if lowered to 2, append CANCEL.
- Row with `status='deleted'`: append a DELETE outbox row; insert parent row with `sync_status='dirty'` for tracking.
- DataJson corrupted or unparseable: move to `documents__orphaned_v1`, log row count per doctype.
- Meta-driven schema for X has a different field list than JSON keys (server-side added/removed fields since this row was saved): for removed fields, ignore the extra JSON keys; for added fields, leave columns NULL; captured in `documents__archived_v1` audit.

**Rollback:** Because `documents__archived_v1` is preserved, if a user hits a fatal migration bug they can `ROLLBACK` back to v1.1.0 of the SDK; the new tables can be dropped and the archived table renamed back. Documented in the migration-guide snippet.

**Gate for P1 claim** ("existing v1.1.0 consumer apps continue to work after migration"):
- Integration test: seed a v1 `documents` table with 100 mixed rows (clean/dirty/deleted, including child table JSONs), run migration, assert 1:1 parent+child row counts, assert outbox row counts match dirty/deleted count, assert all `mobile_uuid`s preserved.
- Smoke test on example app: after migration, user can still open/edit/push previously-dirty rows.

## 13. Decisions log (alternatives considered)

- **Schema: full columnar (chosen) vs. hybrid blob vs. per-doctype JSON.** Full columnar wins on query power and storage efficiency; migration cost accepted (mostly `ALTER TABLE ADD COLUMN`).
- **Link storage: single value + `__is_local` flag (chosen) vs. two exclusive columns.** Single + flag halves column count; filter-parser adds one predicate centrally.
- **Watermark: cursor `(modified, name)` advance-on-success (chosen) vs. timestamp advance-per-page.** Cursor is correct when many rows share `modified` seconds; advance-on-success prevents data skip on mid-pull failure.
- **Push batching: per-doc HTTP with parallelism (chosen) vs. `insert_many` bulk.** Per-doc lets us handle per-row conflicts and retries cleanly; Frappe's `insert_many` caps at 200 and returns names only (no full dicts), which loses the write-back we need.
- **Conflict: auto last-write-wins with one auto-retry (chosen) vs. strict user-mediated.** Chosen for throughput; explicit UI surfaces when auto fails.
- **Delete ordering: no reverse-topo; try-and-handle LinkExists (chosen) vs. pre-sort.** Simpler; Frappe returns the exact blocking links, so user gets an actionable cascade prompt.
- **Pull/push coordination: push-wins with deferred pulls (chosen) vs. mutex.** Push-wins avoids spurious conflicts on fast user-save paths.
- **Logout wipe: delete DB file + recreate (chosen) vs. transaction-wrapped DROP/DELETE.** File delete is OS-atomic; zero risk of partially-wiped state.
- **Retry-all: priority-ordered (chosen) vs. insertion order.** Frontloads likely successes; visible success rate improves dramatically.
- **INSERT idempotency via `mobile_uuid` (chosen) vs. client-generated idempotency key.** `mobile_uuid` is already the client-side PK; adding a second client→server key would be dead surface. Server-side dedup on `mobile_uuid` is sufficient for INSERT; UPDATE relies on `check_if_latest`; SUBMIT/CANCEL are state-idempotent natively.
- **Dependencies: tier-compute in-memory per run (chosen) vs. persistent `depends_on` column.** Tier computation reads already-persistent outbox rows; adding a column adds writer/reader surface with no benefit.

## 14. Open questions

None at design time; decisions 9a–12e logged above.

## 15. Glossary

- **Entry point**: a doctype declared by the consumer app as a home-screen destination; seeds the pull closure.
- **Closure**: transitive set of doctypes reachable from entry points via Link + Table + Table MultiSelect edges.
- **Cursor**: `(modified, name)` pair used for paginated pull resumption.
- **Outbox**: persistent table of pending server ops; survives app kill.
- **Dep-graph**: cached per-doctype dependency graph stored on `doctype_meta.dep_graph_json`; rebuilt on meta-watermark advance.
- **`mobile_uuid`**: client-generated UUID; primary key in every local table; server dedup key for idempotent inserts.
- **`server_name`**: Frappe's final `name`; nullable until insert succeeds.
- **`__is_local` flag**: per-Link-field companion column; 1 iff value is a `mobile_uuid` of a not-yet-synced target.
- **`__norm` column**: per-searchable-field companion column; holds `normalizeForSearch(value)` for accent-/case-insensitive LIKE.
