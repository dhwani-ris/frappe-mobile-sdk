# [2.1.0] - 2026-05-01

### Added

- **Server-driven offline mode toggle** — new `offline_enabled` Check field on `Mobile Configuration` (server-side) controls whether the SDK runs as an offline-first client or a thin online client. Default is off (online). Companion server release: `frappe-mobile-control` 1.x with the `offline_enabled` field surfaced on every authenticated login response.
- **`OfflineMode`** value object exposed via `OfflineMode(enabled, isPersisted)` and `OfflineMode.fallback`.
- **`SdkMetaDao`** — read/write helpers for the persisted offline-mode flag on the existing `sdk_meta` table.
- **`OfflineTransitionService`** — sealed-state stream (`TransitionIdle` / `TransitionDraining` / `TransitionDrainFailed` / `TransitionWipingTables` / `TransitionCompleted`) plus `runDrainAndWipe()`, `retry()`, `forceExit()`. Drives the offline → online migration: pushes pending records, then drops local tables.
- **`OfflineTransitionScreen`** — full-screen UI with `PopScope` guard for drain progress, drain failure, retry, and force-exit confirmation.
- **`OfflineTransitionGuard`** — wraps a child widget and overlays the transition screen for as long as the SDK's transition stream is non-idle. Recommended integration point for consumer apps.
- **`AppDatabase.wipeOfflineDocumentTables()`** — drops every `docs__<doctype>` table and clears `outbox`, `pending_attachments`, `link_options`. Preserves `doctype_meta`, `auth_tokens`, `doctype_permission`, `sdk_meta`.
- **`FrappeSDK.offlineTransition`** getter and **`runOfflineTransitionIfPending()`** public method for explicit foreground orchestration.
- **`doc/OFFLINE_MODE_TOGGLE.md`** — feature documentation, integration guide, and known limitations.

### Changed

- **Schema bump v4 → v5.** `sdk_meta` gains two columns: `offline_enabled INTEGER NOT NULL DEFAULT 0` and `offline_enabled_set_at INTEGER` (epoch ms; NULL until the first login response carries the flag). Migration is automatic and idempotent.
- **`UnifiedResolver`** accepts optional `offlineMode` and `client` parameters. When `offlineMode.enabled = false`, `resolve()` short-circuits to a REST passthrough via `client.doctype.list`. No DB read, no `LinkDecorator`, no background-refresh dedupe.
- **`OfflineRepository`** accepts the same two parameters. `create` / `updateDocumentData` / `deleteDocument` route to `FrappeClient` directly when offline mode is off; `getDirtyDocuments` returns empty.
- **`SyncService`** accepts `offlineMode`. Every public method (`pushSync`, `pullSync`, `pullSyncMany`, `syncDoctype`, `getSyncStats`) returns `SyncResult.empty()` (or zeros) when offline mode is off. Adds `SyncResult.empty()` factory.
- **`FrappeSDK.initialize()`** reads the persisted flag, resolves the session-bound mode via `_resolveBootMode`, and gates the closure pull in `_initialMetaAndDataSync` accordingly.
- **`FrappeSDK.forTesting`** accepts an `offlineMode` parameter (default: offline) so existing tests continue to exercise the offline path without changes.
- **`DoctypeService.list`** now accepts an optional `orFilters` parameter (additive; passes Frappe's `or_filters` query param through).
- **`Mobile Configuration` doctype** (server-side) gains the `offline_enabled` Check field with `depends_on: eval:doc.enabled`. Field is the source of truth for the SDK's behavior.

### Notes for upgraders

- All new constructor parameters are optional with sensible defaults; existing call sites continue to compile and run.
- An existing offline deployment that does **not** flip `offline_enabled = true` on the server before upgrading the SDK to 2.1 will see clients persist `false` on first login and will eventually drain + wipe local data on the next launch. Deploy the server-side update first if you want offline to remain on.
- Token refresh does not refresh the flag; long-lived sessions stay in their previous mode until the user re-authenticates via password / OTP / OAuth / API key.

# [2.0.0] - 2026-04-27

### Added

- **Offline-first data layer** — two-store design: every form save now writes to both the legacy `documents` JSON store and normalized per-doctype `docs__<dt>` / `docs__<child_dt>` SQLite tables via `LocalWriter`.
- **`UnifiedResolver`** — single offline read path for Link pickers, list screens, and `fetch_from`; queries per-doctype tables first, triggers background API refresh when online.
- **`LinkOptionService` offline-first** — backed by `UnifiedResolver`; Link dropdowns now work fully offline.
- **Cursor-based pull** — `SyncService` uses `(modified, name)` cursors with `DoctypePullPhase` (initial / resume / incremental), look-ahead pagination, and resume-on-crash.
- **`pullSyncMany`** — batch pull for multiple doctypes through a bounded worker pool.
- **`getPullPhase` / `getPullPhases`** — query pull phase per doctype for UX gating (blocking screen vs background indicator).
- **UUID-to-server-name resolution on push** — Link fields containing `mobile_uuid` values are rewritten to their `server_name` before the document is sent to the server.
- **`SyncController`** — imperative sync surface: `syncNow`, `pause`/`resume`, `retry`, `retryAll`, `resolveConflict`, `previewDeleteCascade`, `acceptDeleteCascade`; observable `state$` stream.
- **`SessionUser` auto-populated** — all login paths (username/password, OTP, API key, OAuth) now call `SessionUserService.set()` automatically; `sdk.sessionUser` and `sdk.sessionUser$` are available immediately after login.
- **New UI exports** — `MigrationBlockedScreen`, `SyncStatusBar`, `SyncProgressScreen`, `SyncErrorsScreen`, `DocumentListFilterChip`, `showDeleteCascadePrompt`, `showLogoutGuardDialog`, `showForceLogoutConfirm`.
- **`ClosureBuilder` parallel BFS** — level-by-level meta fetching with bounded concurrency (default 4 workers) reduces closure build time on large schemas.
- **`DoctypeService.bulkGetWithChildren`** — batches per-name GET requests into a single `mobile_sync.get_docs_with_children` server call (200 docs/batch); falls back to individual GETs on 404 for older deployments.
- **`RestHelper` improved error messages** — distinguishes "connection refused" from "no internet".
- **`FormScreen` offline-first save** — checks connectivity before save; treats `serverId == null` docs as INSERT when going back online.
- **`doc/OFFLINE_FIRST.md`** — new reference document for the offline-first architecture.

### Changed

- `OfflineRepository` constructor now accepts an optional `LocalWriter` (wired automatically by `FrappeSDK`).
- `LinkOptionService` constructor now takes `UnifiedResolver` + `MetaResolverFn` instead of `FrappeClient`.
- `OfflineRepository.createDocument` preserves an existing `mobile_uuid` from the payload rather than always generating a fresh one.
- `OfflineRepository.getRowFromPerDoctypeTable` added for `fetch_from` offline resolution.
- `UnifiedResolver` translates `parent` filter column to `parent_uuid` for child-table queries.

### Fixed

- `system_tables.dart` — all `CREATE TABLE` statements use `IF NOT EXISTS`; `sdk_meta` seed uses `INSERT OR IGNORE` (migration idempotency).
- `pull_apply.dart` — conflict flag now only fires when the server `modified` timestamp is strictly after the local `modified` (previously flagged any dirty row unconditionally).
- `SyncController.pause()` / `resume()` — `syncNow` now checks the `isPaused` flag before running.

# [1.1.0](https://github.com/dhwani-ris/frappe-mobile-sdk/compare/v1.0.0...v1.1.0) (2026-04-17)


### Bug Fixes

* **auth:** disable social login and auto-discovery ([4382822](https://github.com/dhwani-ris/frappe-mobile-sdk/commit/43828221e73e119c986a6329aa53473eb6964060))
* **review:** move docs to doc/FIELD_TYPES.md, remove pubspec.lock from tracking ([72f7c74](https://github.com/dhwani-ris/frappe-mobile-sdk/commit/72f7c745af60272f1df5a390d0be6366a470f39b))


### Features

* add optional field change handler and improve form data handling ([9012b3e](https://github.com/dhwani-ris/frappe-mobile-sdk/commit/9012b3e1ee02386472793ef8ad07c28387ad4b0e))
* **auth:** implement social login support with OAuth integration ([e123df7](https://github.com/dhwani-ris/frappe-mobile-sdk/commit/e123df7809f806825bf9554087adec24ba616890))
* **fields:** add SearchableSelect, TableMultiSelect, Geolocation field widgets and fix form data handling ([06e8a32](https://github.com/dhwani-ris/frappe-mobile-sdk/commit/06e8a327dc0590c9d8d6c0c797104d6540c695a0))

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.0.0]: https://github.com/dhwani-ris/frappe-mobile-sdk/releases/tag/v1.0.0
