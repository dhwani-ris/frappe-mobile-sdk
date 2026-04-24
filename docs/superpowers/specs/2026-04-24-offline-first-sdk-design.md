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
                   Frappe server + mobile_control
                   (JWT, meta watermark, mobile_uuid dedup)
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
  meta_watermark       TEXT,                         -- from mobile_control; drives migration
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
  state            TEXT    NOT NULL,                 -- pending|in_flight|done|failed|conflict|blocked
  retry_count      INTEGER NOT NULL DEFAULT 0,
  last_attempt_at  INTEGER,
  error_message    TEXT,
  error_code       TEXT,                             -- NETWORK|TIMESTAMP_MISMATCH|LINK_EXISTS|
                                                     -- PERMISSION|VALIDATION|MANDATORY|...
  created_at       INTEGER NOT NULL,
  idempotency_key  TEXT    NOT NULL,                 -- sha256(mobile_uuid|op|created_at)
  depends_on       TEXT                              -- JSON list of outbox.id values
);
CREATE INDEX ix_outbox_state ON outbox(state, created_at);
CREATE INDEX ix_outbox_uuid  ON outbox(mobile_uuid);

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

- `FrappeSDK.initialize()` and app resume (when `Connectivity.isOnline`): fetch `meta_watermark` for each in-scope doctype via `mobile_control`.
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

### 5.7 Idempotency — cross-repo contract

**INSERT is not natively idempotent in Frappe.** Retries would create duplicates. Mitigation:

- Every outbox INSERT payload carries `mobile_uuid`.
- `mobile_control` server app MUST install a `before_insert` hook: if a doc with this `mobile_uuid` already exists in this `doctype`, return the existing dict instead of creating a duplicate.
- SDK asserts `mobileControlMinVersion` on initialize; if server header `X-Mobile-Control-Version` < required → init fails with actionable error.

**UPDATE** — idempotent via Frappe's native `check_if_latest` (client sends snapshot `modified`).
**SUBMIT / CANCEL** — idempotent: Frappe raises specific errors ("already submitted" / "already cancelled"); SDK treats these as success.
**DELETE** — 404 treated as success.

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
- **`DeleteCascadePrompt`** — on `LINK_EXISTS` failure; shows linked docs per doctype with counts; `Delete all` enqueues cascade; `Fix manually` navigates to errors screen.

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

When user triggers `Retry all`, outbox rows re-queued in priority order (1 highest):

| # | Category | Rationale |
|---|---|---|
| 1 | `NETWORK` / `TIMEOUT` | Transient; network is back now |
| 2 | `BLOCKED_BY_UPSTREAM` | Releases dependents on parent success |
| 3 | `CONFLICT` | Often succeeds after auto-merge retry |
| 4 | `LINK_EXISTS` (failed DELETE) | Succeeds only if dependents now deleted |
| 5 | `VALIDATION` / `MANDATORY` | Usually requires user fix |
| 6 | `PERMISSION_DENIED` | Requires role change |
| 7 | Unknown / other | Last |

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

### 9.4 `SDKConfig`

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
  final int mobileControlMinVersion;                // init assertion
}
```

## 10. Server contract — `mobile_control` requirements

Hard dependencies; SDK `initialize()` aborts with actionable error if unmet.

| Endpoint / hook | Purpose | Required behavior |
|---|---|---|
| `POST /api/method/mobile_control.auth.login` | Login + JWT | Returns `SessionUser` payload |
| `GET /api/method/mobile_control.meta.get_watermarks` | Meta change signal | List of `{doctype, meta_version}` |
| `GET /api/method/mobile_control.meta.get_doctype` | Full meta + link_filters | Used by MetaService |
| `before_insert` hook on `frappe.client.insert` | **mobile_uuid dedup** | If doc with `mobile_uuid=X` exists in this doctype, return existing dict — do not create duplicate |
| Response shape on insert | Write-back | Must include `name` + all child rows with their `name` + `modified` |
| `X-Mobile-Control-Version` header | Version guard | SDK asserts `≥ mobileControlMinVersion` |

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
- P3: 10 k-row doctype initial sync on 2 GB / 4-core emulator < 5 min, no UI jank.
- P4: 100 concurrent offline saves → 100 % push success against mock `mobile_control`, no duplication.
- P5: all existing form + list screens work offline identically to online.
- P6: SDK minor-version bump + changelog shipped.

## 12. Phasing

Six independently mergeable plans. Dependencies: P2 ← P1; P3 ← P2; P4 ← P1+P2; P5 ← P3+P4; P6 ← P5.

| # | Phase | Scope |
|---|---|---|
| P1 | Schema foundation + outbox + mobile_uuid dedup | Per-doctype + per-child tables; outbox; pending_attachments; doctype_meta with dep_graph; one-time migration from current single `documents` table preserving existing dirty rows; `mobile_control` `before_insert` dedup hook |
| P2 | Meta service + dependency graph | Closure builder; dep-graph cache; meta-watermark migration engine; `__norm` column population |
| P3 | Pull engine + concurrency utilities | `PullPool`, `WriteQueue`, cursor-based watermark, isolate parse, pull/push coordination gate, `syncState$` stream |
| P4 | Push engine + conflict + attachments | `PushPool`, tier dispatch, UUID rewrite, TimestampMismatch auto-merge, attachment sub-pipeline, outbox state machine, retry-all priority |
| P5 | Unified read resolver + FilterParser | `UnifiedResolver`, dedup + debounce, FilterParser with all operators + null-parity, rewire Link picker + `fetch_from` + list screens |
| P6 | UI surface + lifecycle | All default widgets, `SessionUser` hooks, atomic wipe, consumer theming/copy overrides |

Each phase gets: design reference, implementation, tests to the specified tier, user-facing docs, changelog, migration-guide snippet.

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
