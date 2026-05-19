# What's new in `frappe_mobile_sdk` 2.0

This is the feature-by-feature tour. Each section explains what shipped, why it exists, and how to use it. Code samples target a generic Frappe site and compile against `frappe_mobile_sdk: ^2.0.0`.

For diagrams of how the pieces fit together, see [Architecture](architecture.md). For the full breaking-change list, see [Breaking changes](breaking-changes.md).

---

## 1. Offline-first foundation

The core of the 2.0 release. Every form save writes to a normalized per-doctype SQLite table; reads run against that mirror first; sync happens through an outbox queue.

**What's new:**

- **`OfflineRepository`** (`lib/src/services/offline_repository.dart::OfflineRepository`) — the primary write path for offline-first apps. Manages per-doctype tables and child rows via `LocalWriter`.
- **`OfflineMode`** + **`OfflineModeNotifier`** — session-bound flag that resolves whether reads route to the SQLite mirror (offline) or directly to REST (online).

**Why it exists:** the 1.x `DocumentDao` stored every doc as a JSON blob in a single `documents` table, which made offline list queries impractical (full-table scan + per-row JSON parse). The new schema gives each doctype its own typed columns.

**Minimal usage:**

```dart
final sdk = await FrappeSDK.initialize(autoRestoreAndSync: true);

// Offline-first save (when offline mode is on)
final localId = await sdk.offlineRepository.createDocument(
  doctype: 'Customer',
  data: {'customer_name': 'Acme', 'customer_type': 'Company'},
);

// Reads go through UnifiedResolver — DB-first, background refresh.
final result = await sdk.unifiedResolver.resolve(
  doctype: 'Customer',
  filters: [['customer_type', '=', 'Company']],
);
```

In **online mode** (server flag `offline_enabled = false`), the same calls route to REST without touching the local mirror.

For deep coverage, see [`doc/OFFLINE_FIRST.md`](../OFFLINE_FIRST.md).

---

## 2. Server-driven offline-mode toggle

Whether a deployment runs offline-first or online-only is now decided by a single Check field on the server's `Mobile Configuration` doctype.

**What's new:**

- New `offline_enabled` Check field on the server's `Mobile Configuration` (`depends_on: eval:doc.enabled`).
- The flag is delivered on every authenticated login response by `frappe-mobile-control` ≥ 1.x.
- Persisted client-side in `sdk_meta.offline_enabled` (column added in schema v3).
- Resolved at boot via `lib/src/sdk/frappe_sdk.dart::FrappeSDK._resolveBootMode`.

**Default is OFF (online).** A device with no persisted flag and no offline residue boots online; existing offline deployments must flip the server flag to `true` before upgrading SDK on devices, or clients will drain + wipe local data on first launch.

**Client integration:**

Wrap your app shell with `OfflineTransitionGuard` so the transition UI takes over when the flag flips offline → online:

```dart
MaterialApp(
  builder: (context, child) {
    return OfflineTransitionGuard(
      service: sdk.offlineTransition,
      child: child ?? const SizedBox.shrink(),
    );
  },
  // ...
)
```

For the full server-side setup and transition mechanics, see [`doc/OFFLINE_MODE_TOGGLE.md`](../OFFLINE_MODE_TOGGLE.md).

---

## 3. `UnifiedResolver` — single read path

In 1.x, list screens, Link pickers, and `fetch_from` each had their own read code. 2.0 unifies them.

**What's new:**

- **`UnifiedResolver.resolve(doctype, filters, ...)`** (`lib/src/query/unified_resolver.dart::UnifiedResolver.resolve`) — the single entry point.
- **`FilterParser`** + **`ParsedQuery`** — translate Frappe-style filter lists (`[['field', '=', 'value']]`) into parameter-bound SQLite queries. Pure functions; no I/O.
- **`QueryResult`** + **`RowOrigin`** — every row returned carries origin (`server` vs `localEdit`), enabling provenance-aware UI like the document-list filter chips.
- **`LinkDecorator`** — appends display companions to Link / Dynamic Link values for UI rendering without an extra round-trip.
- **`FrappeTimespan`** — resolves Frappe timespan keywords (`"this month"`, `"last 7 days"`) to absolute ISO ranges offline.
- **`BackgroundFetcher`** — fire-and-forget background refresh: when online and the local mirror is stale, the resolver triggers a single-doctype pull while still returning DB rows immediately.

**Behavior:**

- When offline mode is **enabled**, queries hit `docs__<doctype>` and inject `sync_status NOT IN ('failed')` unless `includeFailed: true`.
- When offline mode is **disabled**, the resolver short-circuits to `client.doctype.list(...)` — no DB read, no decoration, no background fetch.

**Filter support (offline path):**

| Operator | Example | Notes |
|---|---|---|
| `=`, `!=`, `<`, `<=`, `>`, `>=` | `[['amount', '>=', 1000]]` | Direct mapping. |
| `in`, `not in` | `[['status', 'in', ['Open', 'Pending']]]` | Bound parameters. |
| `like`, `not like` | `[['name', 'like', '%Acme%']]` | SQLite `LIKE` semantics. |
| `between` | `[['date', 'between', ['2026-01-01', '2026-12-31']]]` | Inclusive. |
| `is`, `is not` | `[['email', 'is', 'set']]` | Translates to `IS NOT NULL` / `IS NULL`. |
| `Timespan` | `[['modified', 'Timespan', 'this week']]` | Resolved by `FrappeTimespan`. |

Unsupported features raise `lib/src/query/filter_errors.dart::UnsupportedFilterError`; malformed inputs raise `lib/src/query/filter_errors.dart::FilterParseError`.

---

## 4. Tier-ordered push and INSERT idempotency

Push drains the outbox in **dependency-aware tiers** with concurrent dispatch within a tier.

**What's new:**

- **`PushEngine.runOnce`** (`lib/src/sync/push_engine.dart::PushEngine.runOnce`) — main push loop.
- **`TierComputer.compute`** (`lib/src/sync/tier_computer.dart::TierComputer.compute`) — groups outbox rows by inter-pending dependencies. Tier 0 has no upstream pending refs; tier `k` depends only on tiers `< k`. Stable order within a tier: `createdAt asc, id asc`.
- **L1 / L2 / L3 idempotency on INSERT** lives in `lib/src/sync/push_engine.dart::PushEngine._dispatchOnce`:
  - **L1** is a server-side property: `autoname=field:mobile_uuid` makes Frappe reject duplicates by `name == mobile_uuid` natively. Not an SDK code branch.
  - **L2** is `PushEngine._resolveDuplicate` — on `DuplicateEntryError`, fetches the existing doc by name from the exception body or by `mobile_uuid`.
  - **L3** is the pre-retry `GET` by `mobile_uuid` inside `_dispatchOnce`, gated on `IdempotencyLevel.preRetryGetCheck` + retry attempt > 0 + INSERT op; it detects prior successful POSTs that the network dropped.
- **`UuidRewriter.rewrite`** (`lib/src/sync/uuid_rewriter.dart::UuidRewriter.rewrite`) — Link fields containing local `mobile_uuid` values are rewritten to `server_name` before push, using `<field>__is_local` companion columns.

**Outbox row states:**

| State | Meaning |
|---|---|
| `pending` | Waiting to be pushed. |
| `inflight` | Currently being pushed. |
| `synced` | Server accepted; outbox row removed shortly after. |
| `failed` | Validation/permission/network failure after exhausted retries. |
| `conflict` | Server `modified` advanced past the row's base; user resolution needed. |
| `blocked` | An upstream row in a lower tier is not yet `synced`. |

**Retry priority:**

`lib/src/services/retry_priority.dart::RetryPriority` reorders outbox rows on "Retry all" so user-visible errors retry first.

---

## 5. Cursor-based pull

Pull is now delta-only after the first complete page set.

**What's new:**

- **`(modified, name)` watermark cursor** stored per doctype on `doctype_meta.last_ok_cursor` as JSON.
- **`DoctypePullPhase`** — `initial`, `resume`, `incremental`. Phase transitions in [Architecture §6](architecture.md#6-pull-pipeline--cursor-based-delta).
- **Look-ahead pagination** detects the final page (lookahead returns empty) and persists `complete: true`.
- **Resume on crash** — a partial pull resumes from the cursor, not the start.
- **Child doctype guard** — `pullSync` returns empty for `istable=1` doctypes via `lib/src/services/sync_service.dart::SyncService._isChildTable` invoked at the top of `_pullOneInternal`; children come embedded in parent pulls.
- **`pullSyncMany`** — batch pull for multiple doctypes through a bounded worker pool.
- **`getPullPhase` / `getPullPhases`** — query phase per doctype for UX gating.

**UX gating example:**

```dart
final phases = await sdk.syncService.getPullPhases(['Customer', 'Sales Invoice']);

final blocking = phases.values.any((p) =>
    p == DoctypePullPhase.initial || p == DoctypePullPhase.resume);

if (blocking) {
  // Show full-screen progress; skip otherwise
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => SyncProgressScreen(syncStateNotifier: sdk.syncStateNotifier),
  ));
}
```

---

## 6. `SyncController` and the imperative sync surface

`SyncController` exposes a public, imperative API for sync operations and a stream of state snapshots.

> **Do not construct `SyncController` directly.** Its constructor takes internal types (`OutboxDao`, `RunPullFn`, `RunPullForFn`, `FetchSingleDocFn`, `ApplySingleDocFn`, `SyncStateNotifier`) that are intentionally not exported from `frappe_mobile_sdk.dart`. Obtain the wired instance via `sdk.syncController` after `FrappeSDK.initialize()`.

**Surface:**

| Method | Purpose |
|---|---|
| `syncNow()` | Run push + pull once. |
| `pause()` / `resume()` | Soft-halt for the duration of a critical UI flow. |
| `retry(rowId)` | Retry one outbox row. |
| `retryAll()` | Retry all `failed` and `conflict` rows in `RetryPriority` order. |
| `resolveConflict(rowId, action)` | `pullAndOverwriteLocal` or `keepLocalAndRetry`. |
| `previewDeleteCascade(...)` / `acceptDeleteCascade(...)` | Cascade-delete flow when a server DELETE returns `LinkExistsError`. |
| `state$` | `Stream<SyncState>` for UI components to subscribe to. |

```dart
sdk.syncController.state$.listen((state) {
  print('queue: ${state.queue.pending}, errors: ${state.errors.count}');
});
```

`lib/src/sync/sync_state.dart::SyncState` is composable — `DoctypeSyncState` (per-doctype progress), `QueueSummary` (counts), `SyncErrorSummary` (last error).

---

## 7. New sync UI surface

A set of opinionated widgets you can drop into your app shell.

| Widget | What it shows | Where defined |
|---|---|---|
| `SyncStatusBar` | Top-of-screen status strip. | `lib/src/ui/widgets/sync_status_bar.dart::SyncStatusBar` |
| `SyncProgressScreen` | Blocking screen during initial bootstrap pull. | `lib/src/ui/screens/sync_progress_screen.dart::SyncProgressScreen` |
| `SyncErrorsScreen` | List of erroring outbox rows with per-row Retry / View error / Open. | `lib/src/ui/screens/sync_errors_screen.dart::SyncErrorsScreen` |
| `DocumentListFilterChip` | Material `SegmentedButton` for tri-state filtering (all / unsynced / errors) with live counts. | `lib/src/ui/widgets/document_list_filter_chip.dart::DocumentListFilterChip` |
| `OfflineTransitionScreen` | Full-screen offline → online transition UI with `PopScope` guard. | `lib/src/ui/offline_transition_screen.dart::OfflineTransitionScreen` |
| `OfflineTransitionGuard` | Wraps a child; overlays `OfflineTransitionScreen` while non-idle. | `lib/src/ui/offline_transition_guard.dart::OfflineTransitionGuard` |
| `showDeleteCascadePrompt` | Shown when a DELETE fails with `LinkExistsError`. | `lib/src/ui/widgets/delete_cascade_prompt.dart::showDeleteCascadePrompt` |
| `showLogoutGuardDialog` | Soft-gate when Logout is tapped with unsynced rows. | `lib/src/ui/dialogs/logout_guard_dialog.dart::showLogoutGuardDialog` |
| `showForceLogoutConfirm` | Hard-gate requiring "LOGOUT" text entry before destructive logout. | `lib/src/ui/dialogs/force_logout_confirm.dart::showForceLogoutConfirm` |

**Recommended app-shell wiring:**

```dart
return MaterialApp(
  builder: (context, child) {
    return OfflineTransitionGuard(
      service: sdk.offlineTransition,
      child: Column(children: [
        SyncStatusBar(notifier: sdk.syncStateNotifier),
        Expanded(child: child ?? const SizedBox.shrink()),
      ]),
    );
  },
  // ...
);
```

---

## 8. Session user, populated automatically

`lib/src/models/session_user.dart::SessionUser` holds the in-memory snapshot of the logged-in Frappe user. **Every login path** — username/password, OTP, OAuth, API key — calls `SessionUserService.set()` automatically. Restored from `sdk_meta.session_user_json` on session restore.

```dart
final user = sdk.sessionUser;        // SessionUser? — null before first login
sdk.sessionUser$.listen((u) => ...); // Stream<SessionUser?> — fires on login / logout
```

Use this instead of round-tripping `User` from the server in the early app frames — it's already in memory by the time `initialize()` returns.

---

## 9. `LinkFilterBuilder` hook

Static `linkFilters` JSON on a `DocField` is sufficient for many cases. When a Link picker needs **runtime** filters that depend on the current row, the parent form, or session state, register a `LinkFilterBuilder`.

**Key:** Builders are registered against the **target doctype**, not the owning doctype.

```dart
LinkFilterBuilder? customerLinkFilter(String fieldName, String targetDoctype) {
  if (targetDoctype != 'Customer') return null;
  return (field, rowData, parentFormData) {
    final region = parentFormData['region'];
    if (region == null) return const LinkFilterResult(filters: []);
    return LinkFilterResult(filters: [
      ['Customer', 'territory', '=', region],
    ]);
  };
}

FrappeFormBuilder(
  meta: meta,
  // ...
  getLinkFilterBuilder: customerLinkFilter,
);
```

For the full pattern, see [`doc/LINK_FILTER_BUILDER.md`](../LINK_FILTER_BUILDER.md).

---

## 10. Form-level cascade clears

When a Link field's value changes, the SDK auto-clears any other Link field whose `linkFilters` contain `eval:doc.{changed_field}`. Defined inside `lib/src/ui/widgets/form_builder.dart::_FrappeFormBuilderState`'s per-field `onChanged`: when `oldValue != value`, it walks `widget.meta.fields` and removes any `Link` field whose `linkFilters` regex matches `eval\s*:\s*doc.{thisFieldname}`.

**Implication for `FieldChangeHandler` callbacks:** add value-derivation only. The form owns cascade cleanup.

```dart
Map<String, dynamic>? onFieldChange(
  String fieldName,
  dynamic newValue,
  Map<String, dynamic> formData,
) {
  // OK: derive a computed field
  if (fieldName == 'qty' || fieldName == 'rate') {
    final qty = (formData['qty'] ?? 0) as num;
    final rate = (formData['rate'] ?? 0) as num;
    return {'amount': qty * rate};
  }

  // Don't: manually clear dependent Link fields when a parent Link changes —
  // the SDK already does this based on linkFilters.
  return null;
}
```

For the full handler signature and patterns, see [`doc/FIELD_CHANGE_HANDLER.md`](../FIELD_CHANGE_HANDLER.md).

---

## 11. Other enhancements

- **`ClosureBuilder` parallel BFS** — level-by-level meta fetching with bounded concurrency (default 4 workers); reduces closure build time on large schemas.
- **`DoctypeService.bulkGetWithChildren`** — single POST to `mobile_sync.get_docs_with_children` for a chunk of names. Companion **`DoctypeService.listFullDocs`** paginates names from `get_list`, splits them into 200-name chunks (matching the server-side `MAX_BATCH`), and on `404` falls back to per-name `GET` requests with bounded concurrency (slice size 20) for older deployments.
- **`DoctypeService.list` `orFilters`** — additive optional parameter; passes Frappe's `or_filters` query param through.
- **Improved error messages** — `RestHelper` distinguishes "connection refused" from "no internet"; `extractErrorMessage` / `toUserFriendlyMessage` give consistent strings across the SDK.
- **`ApiTracer`** — debug-mode tracing utility for inspecting outbound API calls.
- **`AtomicWipe`** — used during logout-wipe; deletes and rebuilds the SQLite database atomically.

---

## See also

- [Architecture diagrams](architecture.md)
- [Breaking changes](breaking-changes.md)
- [Schema migration](schema-migration.md)
- [Migrating from 1.x](migrating-from-1.x.md)
- [Limitations](limitations.md)
