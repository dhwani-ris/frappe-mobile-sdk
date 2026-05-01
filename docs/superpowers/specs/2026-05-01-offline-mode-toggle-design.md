# Offline Mode Toggle — Server-Driven SDK Switch

**Date:** 2026-05-01
**Scope:** `frappe-mobile-sdk` (Flutter) + `mobile_control` (server)
**Status:** Design — approved by stakeholder
**Target:** Any consumer app of `frappe-mobile-sdk`; SNF as first adopter
**Branch:** `om/offline_improvement`

---

## 1. Context & motivation

The SDK currently treats every install as offline-first: `FrappeSDK.initialize()` always opens SQLite, always wires `OfflineRepository`/`SyncService`/`UnifiedResolver`, and `_initialMetaAndDataSync` pulls the full closure of mobile-form doctypes into local `docs__*` tables on first launch (`lib/src/sdk/frappe_sdk.dart:106-162`, `:512-576`).

Some deployments — internal apps where the user always has network, lightweight mobile-web replacements — don't want this. They want fast form rendering (cached meta) and direct API calls for everything else. The server should decide; the SDK should obey.

This design adds a single server-side toggle on `Mobile Configuration` that, when off (the default), turns the SDK into a thin online client. Meta is still cached locally; documents, outbox, link options, and the closure pull are not.

## 2. Goals and non-goals

### 2.1 Goals

1. Server-side, app-wide on/off switch on `Mobile Configuration` — `offline_enabled` Check, default `0`.
2. Default-online: a missing or false flag yields a pure-network client.
3. Meta cache is always kept (independent of the flag) so forms render instantly on every launch.
4. When `offline_enabled = false`: no `docs__*` tables, no outbox writes, no closure pull, no `link_options` cache. All record reads/writes go to REST.
5. Persisted flag transitions (true → false) drain pending records before wiping local state, with a user-facing exit guard if drain fails.
6. Single trigger point for transitions: `initialize()` reconciles persisted flag against on-disk residue.
7. No mid-session mode flips — the session-bound mode is fixed at `initialize()`.
8. Branch-inside-services implementation (Approach 1) — single read/write path with one short-circuit per public entry point. No parallel `OnlineRepository` codepath.

### 2.2 Non-goals

- Per-form (per-doctype) offline toggle. App-wide only.
- Mid-session mode flip without restart. The persisted value drives the next launch.
- A `mobile_auth.app_status` extension. Login response is the sole delivery channel.
- Background polling for the flag. Refreshed only on full login (not on `refresh_token`).
- Migration of pre-existing offline data when toggling false → true on a previously-online install. The closure pull on next launch handles bootstrap from scratch.

## 3. Server-side change (`mobile_control`)

### 3.1 `Mobile Configuration` doctype

Add one Check field to the existing single doctype (`frappe_mform_snf/apps/mobile_control/mobile_control/mobile_control/doctype/mobile_configuration/mobile_configuration.json`):

```
fieldname:   offline_enabled
fieldtype:   Check
default:     "0"
label:       "Offline Mode Enabled"
depends_on:  eval:doc.enabled
```

Insert into `field_order` immediately after `enabled`. A Frappe patch (`mobile_control/patches/v0_x/set_offline_enabled_default.py`) sets the column to `0` for the existing single — no-op on fresh installs because the default already supplies it.

### 3.2 `mobile_configuration.js` audit

Per the `feedback_client_script_required` rule, JSON+Python doctype changes require a JS audit. The new `offline_enabled` field is a Check with `depends_on: eval:doc.enabled` — the dependency is declarative and Frappe core handles show/hide. **No changes to `mobile_configuration.js` are required.** Audit conclusion recorded here so reviewers don't have to redo it.

### 3.3 Login response payload

`mobile_control/api/helpers/response_builder.py` already calls `get_mobile_configuration_payload()` and merges its output into the login response. Add `offline_enabled` to the payload returned by `get_mobile_configuration_payload()` (`mobile_control/api/helpers/mobile_config.py`):

```python
return {
    "enabled": enabled,
    "offline_enabled": bool(config.offline_enabled) if enabled else False,
    "package_name": ...,
    ...
}
```

Then surface it on the response builder's top-level shape so the SDK can read `response['offline_enabled']` directly (alongside `permissions`, `language`, `roles`).

All four SDK auth surfaces (`api_auth.login`, `verify_mobile_otp`, `mobile_auth.me` for OAuth/API key) must include this key. Centralize through `response_builder.py`.

`mobile_auth.app_status` is **not** changed. It remains for app-version/maintenance checks only.

## 4. SDK boot flow

### 4.1 `OfflineMode` value object

```dart
class OfflineMode {
  final bool enabled;
  final bool isPersisted;
  const OfflineMode({required this.enabled, required this.isPersisted});
  static const fallback = OfflineMode(enabled: false, isPersisted: false);
}
```

`isPersisted = false` indicates the SDK has never seen a login response carrying `offline_enabled` (fresh install OR existing install upgraded to a build with the new column). It is critical for two reasons:

1. **Suppresses spurious transitions** — without it, an existing offline user upgrading their SDK would have their `sdk_meta.offline_enabled` migrated to the column default `0`, and the transition handler (§7.1) would interpret that as "server told me to go online" and wipe their local data before they ever log in again.
2. **Drives boot-mode resolution for legacy installs** — when `isPersisted = false` but residual offline state exists on disk, the SDK assumes the user is mid-upgrade and boots in offline mode for the current session. The next login response then writes the real value.

### 4.2 `sdk_meta` schema additions

Two new columns on the existing single-row `sdk_meta` table:

| Column | Type | Default | Meaning |
|---|---|---|---|
| `offline_enabled` | INTEGER NOT NULL | `0` | `0`/`1`. Default `0` = online. |
| `offline_enabled_set_at` | INTEGER | NULL | Epoch ms of last login response. NULL until first login. |

Schema bumps to v5 with an additive migration (ALTER TABLE ADD COLUMN guarded by the existing duplicate-column tolerator in `_onUpgrade`).

A small `SdkMetaDao` extension exposes:
- `Future<OfflineMode> readOfflineMode()` — returns `.fallback` if the row is missing or `offline_enabled_set_at IS NULL`.
- `Future<void> writeOfflineMode({required bool enabled, required int setAtMs})`.

### 4.3 `FrappeSDK.initialize()` changes

```dart
Future<void> initialize([bool autoRestoreAndSync = false]) async {
  if (_initialized) return;

  _database = await AppDatabase.getInstance(appName: databaseAppName);
  _authService = AuthService();
  _authService!.initialize(baseUrl, database: _database);
  _client = _authService!.client;

  // Read persisted offline mode BEFORE constructing services.
  final persisted = await SdkMetaDao(_database!.rawDatabase).readOfflineMode();
  _offlineMode = await _resolveBootMode(persisted);

  // Construct services with mode passed in (constructor parameter).
  _metaService = MetaService(_client!, _database!);   // unchanged
  _repository = OfflineRepository(_database!, ..., offlineMode: _offlineMode);
  _syncService = SyncService(..., offlineMode: _offlineMode);
  _linkOptionService = LinkOptionService(resolver, metaFn, offlineMode: _offlineMode);
  // UnifiedResolver also takes _offlineMode for its short-circuit.

  _offlineTransitionService = OfflineTransitionService(...);
  _sessionUserService = SessionUserService(_database!.rawDatabase);
  await _sessionUserService!.restoreFromDb();

  _initialized = true;

  if (autoRestoreAndSync) {
    final restored = await _authService!.restoreSession();
    if (restored) {
      // Reconcile persisted flag against on-disk residue. Only fires when
      // the server has explicitly told us to go online (isPersisted=true,
      // enabled=false). Blocks until resolved (drain succeeds, or user
      // force-exits).
      if (persisted.isPersisted &&
          !persisted.enabled &&
          await _hasResidualOfflineState()) {
        await _runOfflineToOnlineTransition();
      }
      await _initialMetaAndDataSync();
    }
  }
}

/// Resolves the session-bound offline mode from the persisted record.
///
/// - Persisted value present → use it verbatim.
/// - Unpersisted + residue on disk → assume legacy offline install, boot offline.
/// - Unpersisted + no residue → fresh install, boot online (the spec default).
Future<OfflineMode> _resolveBootMode(OfflineMode persisted) async {
  if (persisted.isPersisted) return persisted;
  final hasResidue = await _hasResidualOfflineState();
  return OfflineMode(enabled: hasResidue, isPersisted: false);
}
```

`_hasResidualOfflineState()`: returns true iff any `docs__*` table exists OR `outbox` is non-empty OR `pending_attachments` is non-empty. Existence (not row count) of `docs__*` is the right signal because the closure pull may have created tables before any rows landed.

The session-bound `_offlineMode` does NOT change after `initialize()` returns. Login response handling persists the new value but does not rebuild services. Mode changes take effect on the next launch.

### 4.4 Service construction with `offlineMode = false`

When `_offlineMode.enabled == false`:
- `_initialMetaAndDataSync` runs permissions sync + translations + `checkAndSyncDoctypes` + `resyncMobileConfiguration`. The closure pull (`_metaService!.closure(...)` then per-doctype `pullSync`) is skipped.
- `OfflineRepository.ensureSchemaForClosure` is never invoked. Per-doctype `docs__*` tables stay absent.
- `outbox`, `pending_attachments`, `link_options`, `doctype_permission`, and `sdk_meta` tables exist (they're in the base schema and small) but `outbox`/`pending_attachments`/`link_options` stay empty.

## 5. Service-level branches (Approach 1)

### 5.1 `UnifiedResolver.resolve()`

```dart
if (!_offlineMode.enabled) {
  return _onlinePassthrough(
    doctype, filters, orFilters, orderBy, page, pageSize,
  );
}
// existing DB-first + background-refresh path
```

`_onlinePassthrough`:
- Calls `FrappeClient.list(doctype, filters: ..., or_filters: ..., order_by: ..., limit_start: page * pageSize, limit_page_length: pageSize)`.
- Maps response rows to `Map<String, Object?>`. Origin = `RowOrigin.server` for every row. No `sync_status` column injection (callers in online mode never expect one — they bypass it).
- No `LinkDecorator.decorate` step. Frappe REST returns labels for Link fields when the consumer asks for them via `fields=[...]` — if the caller wanted display values, they pass that fields list. The resolver does not synthesize `<field>__display` companions in online mode.
- No `_inflightBg` dedup. Every call hits the network; rate-limiting is the caller's concern.
- Returns `QueryResult` with `originBreakdown` = `{RowOrigin.server: rows.length}`.

### 5.2 `OfflineRepository`

| Method | Behavior when `offlineMode.enabled = false` |
|---|---|
| `query`, `get` | Delegate to `UnifiedResolver` (which short-circuits) — no change |
| `create` | `await _client.document.createDocument(...)` — return server response |
| `update` | `await _client.document.updateDocument(...)` |
| `delete` | `await _client.document.deleteDocument(...)` |
| `getDirtyDocuments` | Returns `[]` |
| `markSynced`, `markFailed`, etc. | No-op |

Attachments: `AttachField` calls `_client.file.uploadFile(...)` synchronously when offline mode is off. No `pending_attachments` enqueue.

### 5.3 `SyncService`

Every public method (`pullSync`, `pushSync`, `flushOutbox`, `flushPendingAttachments`, etc.) returns immediately with a no-op result when `offlineMode.enabled = false`. `SyncStateNotifier` stays in `idle` for the whole session. The `_isSyncing` guard is irrelevant.

### 5.4 `LinkOptionService`

Skip the resolver-cache path. Call `_client.list(targetDoctype, filters, fields, limit)` directly. No write to `link_options`.

### 5.5 `MetaService`

**Unchanged.** Meta is always cached locally. `getMeta`, `prefetchToDb`, `checkAndSyncDoctypes`, `resyncMobileConfiguration`, `closure`, `ensureUpToDate` all behave identically regardless of the flag.

### 5.6 `_initialMetaAndDataSync` split

```dart
Future<void> _initialMetaAndDataSync() async {
  if (!_cachedOnline) return;

  await _permissionService?.syncFromApi();
  await _translationService?.loadTranslations(lang);
  await _metaService!.checkAndSyncDoctypes();
  await _metaService!.resyncMobileConfiguration();

  if (!_offlineMode.enabled) return;   // online mode stops here

  // Existing closure pull
  final entryPoints = await _metaService!.getMobileFormDoctypeNames();
  final closure = await _metaService!.closure(entryPoints);
  ...
}
```

## 6. Login response handling

After every successful authentication (`login`, `verifyLoginOtp`, `_fetchUserInfoAndApply` for OAuth/API key), persist the incoming flag:

```dart
Future<void> _persistOfflineFlagFromLogin(Map<String, dynamic> resp) async {
  final incoming = resp['offline_enabled'] == true;     // missing/null → false
  await SdkMetaDao(_database!.rawDatabase).writeOfflineMode(
    enabled: incoming,
    setAtMs: DateTime.now().millisecondsSinceEpoch,
  );
}
```

That's the entire login-side responsibility. No transition logic, no service rebuild. The persisted value takes effect on the **next** `initialize()` call (typically next app launch).

For the `autoRestoreAndSync = true` path: by the time login response is received, services are already wired with the previous mode. The persisted update positions the next launch correctly. The current session continues in the previous mode until restart, except for the transition reconciliation that `initialize()` performs **before** `_initialMetaAndDataSync` (Section 4.3) — which catches the case where the previous launch persisted `false` but never finished the drain.

## 7. Transition handler (true → false drain)

The transition is detected at `initialize()` time. It does NOT fire from the login response handler.

### 7.1 Trigger condition

```
persisted.isPersisted == true
  AND persisted.enabled == false
  AND _hasResidualOfflineState() == true
```

All three conjuncts are required:

- **`isPersisted = true`** — at least one login response since the SDK gained the feature must have been processed. Without this, an existing offline user upgrading the SDK would be silently transitioned to online and have their data wiped before they ever re-authenticate. The `set_at_ms IS NULL` migration default protects them.
- **`enabled = false`** — the server's most recent decision is "online".
- **residue exists** — there is actually something to drain or wipe.

This catches:
- A previous session received `offline_enabled = false` in the login response, persisted it, and exited without draining.
- The current launch read `false` from `sdk_meta` but the local DB still has `docs__*` tables, queued outbox rows, or queued attachments.

It explicitly does NOT catch:
- Existing offline user who upgraded the SDK and hasn't logged in yet (caught by §4.3 `_resolveBootMode` instead — they boot offline this session).
- Fresh installs (no residue, trigger inert).

### 7.2 State stream

```dart
sealed class OfflineTransitionState {
  const OfflineTransitionState();
}
class Idle extends OfflineTransitionState {}
class Draining extends OfflineTransitionState {
  final int totalRecords, drainedRecords;
}
class DrainFailed extends OfflineTransitionState {
  final int remainingDirty;
  final int remainingFailedAttachments;
  final String? lastError;
}
class WipingTables extends OfflineTransitionState {}
class Completed extends OfflineTransitionState {}
```

A new `OfflineTransitionService` (held by `FrappeSDK`, exposed via `sdk.offlineTransition`) emits these states on a broadcast stream and exposes `retry()` and `forceExit()`.

### 7.3 Flow (`_runOfflineToOnlineTransition`)

1. **Drain.** Construct a transient offline-mode-wired `SyncService` instance just for this step (or temporarily run the existing one in offline-aware mode — see §10.1). Call `flushOutbox()` then `flushPendingAttachments()`. Emit `Draining` snapshots as records drain.
2. **Recheck.** After both flushes, re-evaluate `_hasResidualOfflineState()`.
3. **Success path** — residue is gone. Emit `WipingTables`. Drop all `docs__*` tables and clear `outbox`, `pending_attachments` via `AppDatabase.wipeOfflineDocumentTables()`. Emit `Completed`. Resolve.
4. **Failure path** — residue remains. Emit `DrainFailed{remainingDirty, remainingFailedAttachments, lastError}`. Await user action via:
   - `sdk.offlineTransition.retry()` → re-enter step 1.
   - `sdk.offlineTransition.forceExit()` → drop tables and clear queues unconditionally (`A1` fallback), then emit `Completed`. Resolve.
5. The Future returned by `_runOfflineToOnlineTransition` does not complete until step 3 or 4 reaches `Completed`. `initialize()` blocks on it before calling `_initialMetaAndDataSync`.

### 7.4 Consumer UI surface

The SDK already ships `AppGuard` (`lib/src/ui/app_guard.dart`). Extend its build tree:

```dart
StreamBuilder<OfflineTransitionState>(
  stream: sdk.offlineTransition.stream,
  builder: (ctx, snap) {
    final s = snap.data;
    if (s is Draining || s is DrainFailed || s is WipingTables) {
      return OfflineTransitionScreen(state: s, sdk: sdk);
    }
    return child;
  },
);
```

`OfflineTransitionScreen`:
- Wraps content in `PopScope(canPop: false)` to intercept the OS back button.
- `Draining` view: progress indicator + "Saving your pending records before going online".
- `DrainFailed` view: count of remaining records, last error, two buttons — "Retry" (calls `retry()`) and "Force exit anyway" (confirmation dialog → `forceExit()`).
- `WipingTables` view: "Cleaning up local data".

Caveat: Flutter cannot prevent OS-level swipe-away from recents. Force-exit-via-recents results in data loss. This matches existing logout-with-pending-records behavior; we surface the same warning copy.

### 7.5 `wipeOfflineDocumentTables()`

A new helper on `AppDatabase`:

```dart
Future<void> wipeOfflineDocumentTables() async {
  await _db.transaction((txn) async {
    final tables = await txn.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'docs\\_\\_%' ESCAPE '\\'",
    );
    for (final r in tables) {
      await txn.execute('DROP TABLE IF EXISTS "${r['name']}"');
    }
    await txn.delete('outbox');
    await txn.delete('pending_attachments');
    await txn.delete('link_options');
  });
}
```

Does NOT touch `doctype_meta`, `auth_tokens`, `doctype_permission`, `sdk_meta`. The session continues with cached meta + persisted auth.

### 7.6 Re-entry safety

If the user kills the app mid-drain (any state other than `Completed`), the next launch hits the same trigger condition and re-runs the transition from step 1. `forceExit()` is the only way to exit the loop while residue remains.

## 8. False → true transition (bootstrap offline)

Trivial path:
1. Login response sets `sdk_meta.offline_enabled = 1`.
2. Next `initialize()` reads `enabled = true`. Trigger condition (§7.1) is false (no residue). No transition fires.
3. `_initialMetaAndDataSync` runs the closure pull. Per-doctype `docs__*` tables are created lazily by `OfflineRepository.ensureSchemaForClosure`.

No special handling. The existing offline boot path takes over.

## 9. Error handling

- Login response missing `offline_enabled` key → treated as `false`. Persisted as `false`. Online mode on next launch.
- Login response has `offline_enabled` but `sdk_meta` write fails → log and continue. The next login retries the write. The session uses whatever was already persisted.
- `wipeOfflineDocumentTables()` partial failure → wrapped in transaction; failure rolls back. Re-runs on next `retry()` or `forceExit()`.
- REST call failure in online mode (e.g. `OfflineRepository.create` → network down) → propagates the exception unchanged. The consumer app shows its own error UI. There is no offline retry queue in online mode.
- `MetaService` calls in online mode → unchanged behavior (cache-then-network with bounded LRU).
- `FrappeSDK.dispose()` must call `_offlineTransitionService?.dispose()` to close its broadcast stream controller, in addition to the existing `_sessionUserService?.dispose()`.

### 9.1 Known limitation: token-refresh does not update the flag

Long-lived OAuth sessions auto-refresh tokens (`AuthService` interceptor on 401). The refresh endpoint does not return `offline_enabled`, so a device that hasn't re-authenticated since the server admin flipped the flag will keep operating in its previous mode. The flag is only refreshed when the user goes through a full login flow (password / OTP / OAuth authorization / API key). This is acceptable for the v1 contract — admins who need to force a mode change can invalidate refresh tokens (`Mobile Refresh Token` doctype) to require re-authentication.

### 9.2 Known limitation: missing key on old-server installs

The spec rule "missing key → false" interacts with deployment ordering. If a consumer ships the new SDK but the server is still running pre-`offline_enabled` `mobile_control`, the login response won't have the field and the SDK persists `false`. The next launch's transition trigger (§7.1) requires `isPersisted = true`, so it WILL fire — wiping any existing offline data. **Operational guidance:** deploy the `mobile_control` upgrade first, and only then ship the new SDK to clients. The bootstrap mode in `_resolveBootMode` (§4.3) protects users on the very first launch after the SDK upgrade, but only until their first relogin.

## 10. Open implementation questions (for planning phase)

These are left for the writing-plans skill to resolve, not blockers for the design.

### 10.1 Transient SyncService for drain

`§7.3 step 1` says "construct a transient offline-mode-wired `SyncService` for the drain". The existing `SyncService` was constructed at init with `offlineMode.enabled = false`, so its public methods are no-ops. Two ways to handle:

- (a) Build a one-shot `SyncService` instance inside `_runOfflineToOnlineTransition` with `offlineMode = OfflineMode(enabled: true, isPersisted: true)`, run drain, discard.
- (b) Add an `internalDrain()` method on `SyncService` that bypasses the offline-mode guard, used only by the transition handler.

(a) is cleaner; (b) avoids the small construction cost. Decide during planning.

### 10.2 Logout flow with offline_enabled = true and pending records

The user mentioned the existing logout warning. Today, `auth_service.logout(clearDatabase: true)` calls `AppDatabase.clearAllData()` unconditionally. The transition handler's pattern (drain-or-block before wipe) should be reused for logout when offline is on. Out of scope for this design; flagged as a follow-up.

### 10.3 Test seam in `FrappeSDK.forTesting`

The test constructor builds services without going through `initialize()`. It needs an `offlineMode` parameter so widget tests can exercise both paths. Default to `OfflineMode.fallback` (online) for backwards compatibility.

### 10.4 UI orchestration of the blocking transition

`initialize()` currently blocks `main()` before `runApp` mounts any UI (existing pattern: `await sdk.initialize(autoRestoreAndSync: true); runApp(...)` — see `snf/lib/main.dart`). If the transition handler awaits user input (`retry`/`forceExit` after `DrainFailed`) inside `initialize()`, the user sees a frozen OS splash with no UI feedback because the widget tree is not mounted yet.

Two implementation strategies, to choose during planning:

- (a) **Defer transition out of `initialize()`.** `initialize()` detects the trigger and parks `OfflineTransitionService` in `Draining` (or a new `Pending` state) without awaiting completion. `_initialMetaAndDataSync` is similarly deferred. The consumer's `AppGuard` mounts the UI, observes the state, calls a separate `sdk.completePendingBootstrap()` that runs the drain + meta/data sync chain. SNF's `main.dart` switches from `autoRestoreAndSync: true` to manual orchestration. Cleanest separation; requires consumer-app change.

- (b) **Block `initialize()` but accept frozen-splash UX during drain.** Drain runs to completion (success path) without UI feedback — usually fast. Only if drain *fails* does the OS splash stay frozen, which is recoverable by killing/reopening the app. v1-acceptable; no consumer-app change.

(a) is the right long-term answer; (b) ships faster. Decide during planning. The spec leaves the contract abstract — `OfflineTransitionService` exposes the same state stream and methods either way; only the call site moves.

## 11. Testing surface

- `SdkMetaDao.readOfflineMode/writeOfflineMode` — unit tests for missing row, NULL `set_at`, both flag values.
- `_persistOfflineFlagFromLogin` — table-driven over the four auth surfaces, asserting exactly one `sdk_meta` write each.
- `UnifiedResolver._onlinePassthrough` — integration test against a fake `FrappeClient`, asserting no DB read.
- `OfflineRepository.create/update/delete` in online mode — fake client, assert no `outbox` insert.
- `_runOfflineToOnlineTransition` — four scenarios: clean drain → wipe → completed; failed drain → retry → success; failed drain → force-exit; killed mid-drain → next launch re-enters.
- `_resolveBootMode` — three scenarios: persisted-online, persisted-offline, unpersisted-with-residue (boots offline), unpersisted-without-residue (boots online).
- §7.1 trigger guard — assert that `isPersisted = false` + residue does NOT fire the transition (regression guard for the existing-user-upgrades scenario).
- `FrappeSDK.dispose()` closes `OfflineTransitionService`'s stream controller — assert via stream-error or post-dispose subscribe.
- `AppDatabase.wipeOfflineDocumentTables` — asserts only `docs__*`, `outbox`, `pending_attachments`, `link_options` are touched; `doctype_meta`, `auth_tokens`, `doctype_permission`, `sdk_meta` are preserved.
- `_initialMetaAndDataSync` skips the closure pull when offline mode is off — assert with a recording fake `SyncService`.
- End-to-end widget test of `OfflineTransitionScreen` showing PopScope blocks back navigation.

## 12. Summary of changes

| Area | Change |
|---|---|
| `mobile_control/.../mobile_configuration.json` | Add `offline_enabled` Check field, default 0 |
| `mobile_control/.../mobile_config.py` | Include `offline_enabled` in payload |
| `mobile_control/api/helpers/response_builder.py` | Pass through to login response top-level |
| `mobile_control/patches/v0_x/...` | Patch to set `offline_enabled = 0` for existing single |
| `lib/src/database/schema/system_tables.dart` | Add `offline_enabled` and `offline_enabled_set_at` columns to `sdk_meta` |
| `lib/src/database/app_database.dart` | Schema bump v4 → v5; `wipeOfflineDocumentTables()` helper |
| `lib/src/database/daos/sdk_meta_dao.dart` (new) | `readOfflineMode`/`writeOfflineMode` |
| `lib/src/sdk/frappe_sdk.dart` | Field `_offlineMode`; pass into services; `_resolveBootMode` (§4.3) + reconciliation in `initialize`; `_persistOfflineFlagFromLogin` after each auth call; gate closure pull; `dispose()` also disposes `OfflineTransitionService` |
| `mobile_configuration.js` | Audit only — no changes required (§3.2) |
| `lib/src/services/offline_repository.dart` | Online passthrough for create/update/delete; `getDirtyDocuments` returns `[]` |
| `lib/src/services/sync_service.dart` | Public-method short-circuit when offline mode is off |
| `lib/src/services/link_option_service.dart` | Online passthrough |
| `lib/src/query/unified_resolver.dart` | `_onlinePassthrough` short-circuit at top of `resolve()` |
| `lib/src/services/offline_transition_service.dart` (new) | State stream + `retry`/`forceExit` |
| `lib/src/ui/app_guard.dart` | Mount `OfflineTransitionScreen` when state ≠ idle |
| `lib/src/ui/offline_transition_screen.dart` (new) | Drain progress, retry/force-exit UI, PopScope guard |
| `frappe-mobile-sdk/pubspec.yaml` | Version bump (1.1.0 → 1.2.0) reflecting the new server contract dependency |
| `snf/lib/main.dart` (consumer) | Conditional change — only if §10.4 (a) is chosen during planning |
