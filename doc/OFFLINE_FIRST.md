# Offline-First Architecture

This document describes the offline-first data layer introduced in the 2.0 rewrite. It covers the two-store design, pull/push lifecycle, sync controller, and the new UI surface.

---

## Overview

The SDK maintains **two parallel stores** for every document:

| Store | Table | Purpose |
|-------|-------|---------|
| Legacy blob store | `documents` (JSON) | Source of truth for push; unchanged from v1 |
| Per-doctype store | `docs__<doctype>` | Normalized columns; enables offline Link pickers, filter queries, and `fetch_from` |

Every form save writes to both stores (`OfflineRepository` + `LocalWriter`). The offline read path (`UnifiedResolver`) queries the per-doctype tables and falls back to a background API refresh when the device is online.

---

## Pull Lifecycle

### Pull Phases

`SyncService.getPullPhase(doctype)` returns a `DoctypePullPhase` that drives UX choices:

| Phase | Meaning | UX |
|-------|---------|----|
| `initial` | Doctype has never been pulled | Show blocking "Preparing offline data" screen |
| `resume` | Pull started but was interrupted (network drop, app kill) | Show same screen with "resuming" hint |
| `incremental` | At least one full pull completed | Background indicator only; delta pull fetches only new/changed rows |

```dart
final phase = await sdk.sync.getPullPhase('Customer');
// or bulk:
final phases = await sdk.sync.getPullPhases(['Customer', 'Item', 'Lead']);
```

### Cursor-Based Pagination

The pull engine uses `(modified, name)` as a stable cursor:

- Pages are fetched in `modified asc, name asc` order.
- After each page the cursor is persisted with `complete: false` (resume marker).
- When the final (short) page lands the cursor flips to `complete: true` (incremental watermark).
- On resume the engine skips rows that sort `<= cursor` to avoid double-applying rows from the tie group.

### Batch Pull

```dart
// Pull up to 45 doctypes through a 4-worker pool
final results = await sdk.sync.pullSyncMany(
  doctypes: toPull,
  concurrency: 4,  // default
);
```

Individual doctype failures do not abort the rest of the batch.

### Server Endpoint Requirement

`listFullDocs` (used for doctypes that have child tables) calls the server endpoint:

```
POST /api/method/mobile_sync.get_docs_with_children
{ "doctype": "...", "names": [...] }
```

This endpoint must be present in the `frappe-mobile-control` companion app. When the endpoint returns 404 (older deployments), the SDK automatically falls back to individual per-name GET requests — bulk performance is lost but correctness is preserved.

---

## Write Path

### LocalWriter

`LocalWriter` mirrors a form save into the per-doctype `docs__<dt>` parent table and all child `docs__<child_dt>` tables in a single SQLite transaction.

- Reuses an existing `mobile_uuid` from the payload, or generates a fresh one.
- Sets `sync_status = 'dirty'` for offline saves; `sync_status = 'synced'` for server-confirmed saves.
- Silently no-ops when the parent table doesn't exist yet (initial pull hasn't run).

`LocalWriter` is wired automatically inside `OfflineRepository` — callers do not instantiate it directly.

### UUID-to-Server-Name Resolution (Push)

Before sending a document to the server, `SyncService` rewrites any `mobile_uuid`-shaped values in Link fields to their corresponding `server_name`. This prevents server-side "Document not found" errors for offline-created docs that reference other offline-created docs.

Lookup order per UUID:
1. Legacy `documents` table — `localId = uuid` with a non-null `serverId`.
2. Per-doctype table — `mobile_uuid = uuid` with a non-null `server_name`.

---

## Read Path: UnifiedResolver

`UnifiedResolver` is the single read path for all offline queries (Link pickers, list screens, `fetch_from`).

```
resolve(doctype, filters, page, pageSize)
  ├── query docs__<doctype> with FilterParser
  ├── if online & stale → background fetch via SyncService.pullSync
  └── return QueryResult(rows, hasMore)
```

`LinkOptionService` is now backed by `UnifiedResolver` instead of the API client — Link dropdowns work fully offline.

### Child Table Parent Filter

Frappe link_filters use the virtual `parent` column (server_name of parent). `UnifiedResolver` automatically translates `parent = <value>` to `parent_uuid = <resolved>`:
1. Direct match — value is already a `parent_uuid`.
2. Server-name lookup — walks each distinct `parent_doctype` table to find the corresponding `mobile_uuid`.

---

## SyncController

`SyncController` is the public imperative surface for sync operations. It wraps `OutboxDao`, `SyncStateNotifier`, and the injected pull/push runners.

```dart
final ctrl = sdk.syncController; // exposed from FrappeSDK

// Trigger a full pull + push cycle (no-op while paused)
await ctrl.syncNow();

// Pause / resume (prevents new syncNow cycles; in-flight ops are not interrupted)
await ctrl.pause();
await ctrl.resume();

// Cancel the initial-sync blocking screen
await ctrl.cancelInitialSync();

// Retry a single failed row
await ctrl.retry(outboxId);

// Retry all failed / blocked / conflict rows (sorted by priority)
await ctrl.retryAll();
await ctrl.retryAll(filterDoctypes: ['Customer']);

// Resolve a conflict row
await ctrl.resolveConflict(
  outboxId: id,
  action: ConflictAction.pullAndOverwriteLocal,  // discard local edits
  // or: ConflictAction.keepLocalAndRetry        // re-run ThreeWayMerge
);

// Delete-cascade flow
final plan = await ctrl.previewDeleteCascade(outboxId);
if (plan != null) {
  // show plan.blockedBy to user …
  await ctrl.acceptDeleteCascade(outboxId);  // reset to pending + push
}

// Observe sync state (for progress UIs)
final SyncState current = ctrl.state;
final Stream<SyncState> stream = ctrl.state$;
```

`SyncState` fields:
- `isPaused` — whether `syncNow` is blocked.
- `isInitialSync` — drives the blocking initial-sync screen.
- `perDoctype` — `Map<String, DoctypeSyncState>` for per-doctype progress.
- `errorSummary` — aggregate of failed/conflict/blocked rows.

---

## Session User

All login paths now automatically persist a `SessionUser`:

```dart
// After any login (username/password, OTP, API key, OAuth)
final user = sdk.sessionUser;        // SessionUser? (null before login)
final stream = sdk.sessionUser$;     // Stream<SessionUser?>

// Or via the service
final svc = sdk.sessionUserService;
await svc.set(SessionUser(...));     // override if needed
await svc.clear();                   // on logout
```

`SessionUser` fields:
- `name` — Frappe user email / username.
- `fullName`, `userImage` — display info.
- `roles` — list of assigned roles.
- `permissions` — doctype-level permission map.
- `userDefaults` — Frappe user defaults (company, territory, etc.).
- `extras` — additional response fields.

For username/password and OTP logins the `roles` and `fullName` come from the login response. For OAuth and API-key logins `SessionUser` is populated from `mobile_auth.me` (which includes `user_image`, `user_defaults`, and `permissions`).

---

## New UI Components

All components are exported from `frappe_mobile_sdk.dart`.

### `SyncStatusBar`

Compact status bar widget showing the current `SyncState`. Intended for the app's bottom bar or persistent header.

```dart
SyncStatusBar(state: ctrl.state)
```

### `SyncProgressScreen`

Blocking screen shown during initial/resume sync. Displays per-doctype progress.

```dart
SyncProgressScreen(ctrl: sdk.syncController)
```

### `SyncErrorsScreen`

Lists all failed / conflict / blocked outbox rows with retry and resolve actions.

```dart
SyncErrorsScreen(ctrl: sdk.syncController)
```

### `MigrationBlockedScreen`

Shown when a pending DB schema migration cannot run (e.g. unsupported downgrade). Prompts the user to update the app.

```dart
MigrationBlockedScreen()
```

### `DocumentListFilterChip`

Chip bar for filtering a `DocumentListScreen` by sync status or custom criteria.

```dart
DocumentListFilterChip(
  filter: currentFilter,
  counts: DocumentListFilterCounts(dirty: 3, failed: 1),
  onChanged: (f) => setState(() => currentFilter = f),
)
```

### Dialogs

```dart
// Before logout: warns about unsynced data
final action = await showLogoutGuardDialog(context, pendingCount: 3);

// Force logout (skips guard)
final confirmed = await showForceLogoutConfirm(context);

// Delete with linked-document cascade confirmation
final action = await showDeleteCascadePrompt(context, plan: deleteCascadePlan);
```

---

## Closure Builder

`ClosureBuilder` performs a BFS over Frappe's Link / Table / Table MultiSelect edges to build the dependency closure for a set of entry-point doctypes. The closure determines which doctypes must be pulled before the user can use the app offline.

From v2 the BFS is **level-parallel**: all doctypes at the same BFS depth are fetched concurrently through a bounded worker pool (default 4), reducing closure build time on large schemas.

```dart
final result = await ClosureBuilder.build(
  entryPoints: mobileFormDoctypes,
  metaFetcher: sdk.meta.getMeta,
  metaConcurrency: 4,
);
// result.doctypes — full closure
// result.childDoctypes — child-only doctypes (ride along with parents)
```

---

## Server Requirements

| Endpoint | Required for | Fallback |
|----------|-------------|---------|
| `mobile_auth.login` | All login flows | None |
| `mobile_auth.me` | OAuth / API-key session | Partial SessionUser from login response |
| `mobile_sync.get_docs_with_children` | Efficient pull for doctypes with child tables | Per-name GET (slow for large doctypes) |

The `mobile_sync.get_docs_with_children` endpoint is part of the `frappe-mobile-control` companion app. It accepts `{ "doctype": "...", "names": [...] }` (max 200 names per call) and returns full documents including embedded child rows.
