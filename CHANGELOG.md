# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - Unreleased

Major release: offline-first foundation, server-driven offline-mode toggle, and a new query/sync surface. Upgrades from `1.x` use a single transactional migration from database schema v2 to v3.

### Added

**Offline foundation**

- `OfflineMode` value object (`enabled`, `isPersisted`) bound to a session, plus `OfflineModeNotifier`. The mode is persisted in `sdk_meta` and re-resolved on each launch.
- `OfflineRepository` — primary write path for local edits; manages per-doctype tables and child rows via `LocalWriter`.
- `OfflineTransitionService` with sealed-state stream (`TransitionIdle`, `TransitionDraining`, `TransitionDrainFailed`, `TransitionWipingTables`, `TransitionCompleted`) plus `runDrainAndWipe()`, `retry()`, `forceExit()`. Drives the offline → online transition: drains pending records, then drops local data tables.
- `OfflineTransitionScreen` — full-screen transition UI with `PopScope` guard; drain progress, drain failure, retry, and force-exit flows.
- `OfflineTransitionGuard` — wraps a child widget and overlays the transition screen for as long as the SDK's transition stream is non-idle. Recommended integration point for consumer apps.
- `AtomicWipe` — deletes and rebuilds the SQLite database atomically; used during logout-wipe.
- `FrappeSDK.offlineTransition` getter and `runOfflineTransitionIfPending()` for explicit foreground orchestration.

**Query / read path**

- `UnifiedResolver` — single offline-first read path used by Link pickers, list screens, and `fetch_from`. DB-first; background API refresh when online.
- `FilterParser` + `ParsedQuery` — translate Frappe-style filter lists into parameter-bound SQLite queries; pure functions, no I/O.
- `QueryResult` + `RowOrigin` — read results carry per-row provenance (local edit vs server) for filter chips and observability.
- `LinkDecorator` + `TargetMetaResolver` — display companions for Link / Dynamic Link values.
- `FrappeTimespan` + `TimespanRange` — Frappe-style timespan keywords resolved to absolute ISO ranges offline.

**Link fields**

- `LinkFilterBuilder` callback — runtime filter builder for link-option fetch, keyed on the **target doctype**. Replaces static `linkFilters` JSON when dynamic field/row dependencies are needed.
- `LinkOptionService` — offline-first Link picker; routes through `UnifiedResolver` with DB-first reads and background refresh.
- `LinkFieldCoordinator` — dependency-aware sequencing and progress tracking for cascading Link fields.

**Sync engine**

- Cursor-based pull. `SyncService` uses `(modified, name)` cursors with `DoctypePullPhase` (`initial` / `resume` / `incremental`), look-ahead pagination, and resume-on-crash. Final-page lookahead persists `complete: true` and transitions to `incremental`.
- Tier-ordered push. `PushEngine` drains the outbox via `TierComputer`-grouped dispatch — tier 0 has no inter-pending dependencies; tier k depends only on tiers `< k`. Concurrent dispatch within a tier; stable order `createdAt asc, id asc`.
- L1 / L2 / L3 idempotency on INSERT. L1 uses `autoname=field:mobile_uuid`; L2 uses a consumer-supplied dedup hook; L3 GETs by `mobile_uuid` to detect prior successful POSTs before retry.
- `pullSyncMany` — batch pull for multiple doctypes through a bounded worker pool.
- `getPullPhase` / `getPullPhases` — query pull phase per doctype for UX gating (blocking screen vs background indicator).
- UUID rewrite on push. `UuidRewriter` rewrites Link fields containing `mobile_uuid` values to their `server_name` before push, using `<field>__is_local` companion columns.
- Three-key child identity match on pull-apply (`server_name → mobile_uuid → position`); preserves UUIDs across re-pulls and avoids orphaning Link references.
- `SyncController` — public imperative surface: `syncNow`, `pause` / `resume`, `retry`, `retryAll`, `resolveConflict`, `previewDeleteCascade`, `acceptDeleteCascade`. Observable `state$` stream.
- `SyncState`, `DoctypeSyncState`, `QueueSummary`, `SyncErrorSummary`, `SyncStateNotifier` — composable sync-state snapshot for UI widgets; per-doctype progress, queue counts, last error.
- `RetryPriority` — reorders outbox rows for "Retry all" so user-visible errors retry first.

**Sync UI**

- `SyncStatusBar`, `SyncProgressScreen`, `SyncErrorsScreen` — status bar, blocking bootstrap-pull screen, errors list with per-row Retry / View error / Open actions and a header Retry-all.
- `DocumentListFilterChip` (with `DocumentListFilter` / `DocumentListFilterCounts`) — Material `SegmentedButton` chip for tri-state filtering (all / unsynced / errors) with live counts.
- `showDeleteCascadePrompt` (with `DeleteCascadeAction`) — shown when DELETE fails with `LinkExistsError`; lets the user delete-all, fix-manually, or cancel.
- `showLogoutGuardDialog` (with `LogoutGuardAction`) — soft-gate dialog when Logout is tapped with unsynced rows.
- `showForceLogoutConfirm` — hard-gate dialog requiring "LOGOUT" text entry before destructive logout.

**Session**

- `SessionUser` value object plus `SessionUserService` — owns the in-memory session user and publishes changes via stream.
- All login paths (username/password, OTP, API key, OAuth) now populate `SessionUser` automatically. `sdk.sessionUser` and `sdk.sessionUser$` are available immediately after login.
- Persisted to `sdk_meta.session_user_json` so restore-session paths rehydrate without an extra round-trip.

**Server-driven offline-mode toggle** (companion server feature)

- New `offline_enabled` Check field on the server-side `Mobile Configuration` doctype controls whether the SDK runs as an offline-first client or a thin online client. Default is **off** (online).
- Companion server release: `frappe-mobile-control` 1.x with `offline_enabled` surfaced on every authenticated login response.
- `SdkMetaDao` — read/write helpers for the persisted offline-mode flag on `sdk_meta`.

**Other**

- `ClosureBuilder` — parallel BFS, level-by-level meta fetching with bounded concurrency (default 4 workers); reduces closure build time on large schemas.
- `DoctypeService.bulkGetWithChildren` — batches per-name GET requests into a single `mobile_sync.get_docs_with_children` call (200 docs/batch); falls back to individual GETs on 404 for older deployments.
- `DoctypeService.list` accepts an optional `orFilters` parameter (additive; passes Frappe's `or_filters` query param through).
- `RestHelper` — error messages distinguish "connection refused" from "no internet".
- `FormScreen` offline-first save — checks connectivity before save; treats `serverId == null` docs as INSERT when going back online.
- `ApiTracer` — debug-mode tracing utility for API calls.
- `extractErrorMessage` / `toUserFriendlyMessage` — shared helpers for error-string normalization across the SDK.

### Changed

- **Single read path.** All list reads route through `UnifiedResolver`. DB-first with background refresh on connectivity; Link decoration via `LinkDecorator`.
- **`pullSync` guards child doctypes.** Doctypes with `istable=1` are skipped at the entrypoint — `frappe.client.get_list` does not permit listing them, and children arrive embedded in parent pulls.
- **Form-level cascade clears.** When a Link field changes, the SDK auto-clears dependent Link fields whose `linkFilters` contain `eval:doc.{fieldname}` references. Consumer `FieldChangeHandler` callbacks should add value-derivation only — the form owns cascade cleanup.
- **Local UUID resolution.** Values matching the v4-UUID shape resolve from `docs__*` only; the SDK never calls `getByName(...)` for UUID-shaped values, since server names never match the UUID pattern.
- **Conflict surfaces.** When a pulled row is newer than a local dirty/failed row, `PullApply` sets `sync_status = 'conflict'`. Resolve via `SyncController.resolveConflict()` with two actions: `pullAndOverwriteLocal` (apply server snapshot) or `keepLocalAndRetry` (requeue; runs `ThreeWayMerge` against the pre-edit base).
- **Mobile-UUID round-trip.** After a successful first push, `OfflineRepository.reconcileServerSave` attaches the server's `server_name` to the local row keyed by `mobile_uuid`, cancels pending outbox rows for the pair, and applies the full server snapshot so server-derived columns (defaults, formulas) land in the mirror.
- **`OfflineRepository`** constructor — accepts an optional `LocalWriter`, plus `OfflineMode` and `FrappeClient`. When offline mode is off, `create` / `updateDocumentData` / `deleteDocument` route to `FrappeClient` directly; `getDirtyDocuments` returns empty.
- **`OfflineRepository.createDocument`** — preserves an existing `mobile_uuid` from the payload rather than always generating a fresh one.
- **`OfflineRepository.getRowFromPerDoctypeTable`** — added for `fetch_from` offline resolution.
- **`UnifiedResolver`** — translates the `parent` filter column to `parent_uuid` for child-table queries. Accepts optional `OfflineMode` and `FrappeClient`; when offline mode is off, `resolve()` short-circuits to a REST passthrough (no DB read, no `LinkDecorator`, no background-refresh dedupe).
- **`LinkOptionService`** constructor — now takes `UnifiedResolver` and a meta-resolver instead of `FrappeClient`.
- **`SyncService`** — accepts `OfflineMode`. Every public method (`pushSync`, `pullSync`, `pullSyncMany`, `syncDoctype`, `getSyncStats`) returns `SyncResult.empty()` (or zeros) when offline mode is off. Adds the `SyncResult.empty()` factory.
- **`FrappeSDK.initialize()`** — reads the persisted offline-mode flag, resolves the session-bound mode via `_resolveBootMode`, and gates closure pull in `_initialMetaAndDataSync` accordingly. `autoRestoreAndSync` defaults to `false`; when `true`, restores session and runs post-login bootstrap.
- **`FrappeSDK.forTesting`** — accepts an `offlineMode` parameter (default: offline) so existing tests continue to exercise the offline path.

### Removed

- **`DocumentDao`** — deleted, no replacement. All single-bag CRUD is replaced by `OfflineRepository` + `UnifiedResolver`.
- **Legacy `documents` table** — dropped during the v2 → v3 migration. The single-bag JSON store is replaced by per-doctype `docs__<doctype>` tables. Drop is safe because `1.x` devices push before persisting, so there are no unsynced rows in `documents` at upgrade time.

### Schema

- **`AppDatabase._version` bumped from `2` to `3`.** `sdk_meta.schema_version` is written in lockstep by both `_onCreate` and the upgrade path.
- **Single migration step** `_migrateV2ToV3` runs entirely within one transaction and replaces any prior multi-step v3→v4→v5→v6 chain.
- **Steps:** (1) safely add v3 + v4 column extensions to `doctype_meta` via wrapped `ALTER TABLE ADD COLUMN` (catches "duplicate column name"); (2) idempotently create system tables (`outbox`, `pending_attachments`, `sdk_meta`) with `CREATE TABLE IF NOT EXISTS`; (3) drop the legacy `documents` table and its indexes; (4) upsert the singleton `sdk_meta` row with `schema_version = 3`.
- **Storage layers:**
  - **Per-doctype mirror** — `docs__<doctype>` tables with `mobile_uuid` PK, `server_name`, `sync_status`, `sync_op`, `push_base_payload`, and field columns. Children carry `parent_uuid`. Tables are **lazily created** on first pull via `OfflineRepository.ensureSchemaForClosure`.
  - **System** — `sdk_meta` (singleton row tracking `schema_version`, bootstrap state, offline mode, session user); `outbox` (operation log indexed by state + created_at); `pending_attachments` (file upload queue with retry).
- Fresh installs and migrated devices end in identical schema state.

### Fixed

- `system_tables.dart` — all `CREATE TABLE` statements use `IF NOT EXISTS`; `sdk_meta` seed uses `INSERT OR IGNORE` for migration idempotency.
- `pull_apply.dart` — conflict flag now only fires when the server `modified` timestamp is strictly after the local `modified` (previously flagged any dirty row unconditionally).
- `SyncController.pause()` / `resume()` — `syncNow` now checks the `isPaused` flag before running.

### Notes for upgraders

- All new constructor parameters are optional with sensible defaults; existing call sites continue to compile and run.
- Offline mode is **off by default**. To run as an offline-first client, deploy the `frappe-mobile-control` server release that flips `offline_enabled = true` on `Mobile Configuration` **before** upgrading the SDK on devices. An offline deployment that does **not** flip the flag will see clients persist `false` on first login and drain + wipe local data on the next launch.
- Token refresh does not refresh the offline-mode flag. Long-lived sessions stay in their previous mode until the user re-authenticates (password / OTP / OAuth / API key).
- Existing tests that use `FrappeSDK.forTesting` continue to default to offline. To exercise the online-only path in tests, pass `offlineMode: const OfflineMode(enabled: false, isPersisted: true)`.
- Downgrade is not supported. `sqflite` does not provide a downgrade hook; users cannot downgrade through the app stores.

# [1.1.0](https://github.com/dhwani-ris/frappe-mobile-sdk/compare/v1.0.0...v1.1.0) (2026-04-17)


### Bug Fixes

* **auth:** disable social login and auto-discovery ([4382822](https://github.com/dhwani-ris/frappe-mobile-sdk/commit/43828221e73e119c986a6329aa53473eb6964060))
* **review:** move docs to doc/FIELD_TYPES.md, remove pubspec.lock from tracking ([72f7c74](https://github.com/dhwani-ris/frappe-mobile-sdk/commit/72f7c745af60272f1df5a390d0be6366a470f39b))


### Features

* add optional field change handler and improve form data handling ([9012b3e](https://github.com/dhwani-ris/frappe-mobile-sdk/commit/9012b3e1ee02386472793ef8ad07c28387ad4b0e))
* **auth:** implement social login support with OAuth integration ([e123df7](https://github.com/dhwani-ris/frappe-mobile-sdk/commit/e123df7809f806825bf9554087adec24ba616890))
* **fields:** add SearchableSelect, TableMultiSelect, Geolocation field widgets and fix form data handling ([06e8a32](https://github.com/dhwani-ris/frappe-mobile-sdk/commit/06e8a327dc0590c9d8d6c0c797104d6540c695a0))

## [1.0.0] - 2026-04-01

### Added

- Initial stable release of **Frappe Mobile SDK** for Flutter (`frappe_mobile_sdk`).
- **Frappe API client** — authentication (password, OAuth, API key, mobile OTP), CRUD, file upload, custom methods, and query-style access via `FrappeClient`.
- **Stateless mobile auth** — `mobile_auth.login` integration with token persistence, session restore, and automatic token refresh.
- **Dynamic forms** — metadata-driven rendering from Frappe DocTypes (`FrappeFormBuilder`, list and document screens).
- **Offline-first data layer** — SQLite storage, offline repository, and bi-directional sync with conflict handling.
- **App guard** — `FrappeAppGuard` for server-driven app status, versioning, and force-update flows (requires [Frappe Mobile Control](https://github.com/dhwani-ris/frappe_mobile_control) on the server).
- **Translations** — load dictionaries from the server and apply to labels in forms and lists.
- **Workflows** — workflow state and transitions on forms when configured on the DocType.
- Example app under `example/` and in-repo docs under `doc/`.

[2.0.0]: https://github.com/dhwani-ris/frappe-mobile-sdk/releases/tag/v2.0.0
[1.0.0]: https://github.com/dhwani-ris/frappe-mobile-sdk/releases/tag/v1.0.0
