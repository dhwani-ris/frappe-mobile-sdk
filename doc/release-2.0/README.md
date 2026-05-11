# Frappe Mobile SDK 2.0 — Release Documentation

This folder is the entry point for everything you need to understand, adopt, or upgrade to **`frappe_mobile_sdk` 2.0.0**.

If you only have one minute, read [the TL;DR](#tldr) below.
If you are upgrading from 1.x, jump to [Migrating from 1.x](migrating-from-1.x.md).
If you want to know how the new internals work, read [Architecture](architecture.md).

---

## TL;DR

- **Major release.** Public API broke. Bump dependencies and follow the upgrade guide.
- **Offline-first foundation.** Per-doctype SQLite tables (`docs__<doctype>`), an `outbox` push queue, and a single read path through `UnifiedResolver`.
- **Server-driven offline-mode toggle.** New `offline_enabled` Check field on the server's `Mobile Configuration`. **Default is off** (online-only). Companion server release: `frappe-mobile-control` 1.x.
- **Schema bump v2 → v3.** Single transactional migration step. Legacy `documents` table is dropped.
- **`DocumentDao` removed.** Replaced by `OfflineRepository` + `UnifiedResolver`.
- **New sync UI surface.** `SyncStatusBar`, `SyncErrorsScreen`, `SyncProgressScreen`, `OfflineTransitionGuard`, delete-cascade and logout-guard dialogs.
- **One-step upgrade.** A device on `1.1.0` (schema v2) upgrades cleanly to `2.0.0` (schema v3) on the next launch.

---

## What's in this folder

```
doc/release-2.0/
├── README.md             ← you are here
├── whats-new.md          ← feature-by-feature, with examples
├── architecture.md       ← diagrams: services, init flow, read path, sync, schema
├── breaking-changes.md   ← removed / renamed / signature-changed APIs
├── schema-migration.md   ← v2 → v3 schema migration in detail
├── migrating-from-1.x.md ← step-by-step upgrade checklist
└── limitations.md        ← known gotchas and deferred items
```

| Doc | When to read it |
|---|---|
| [whats-new.md](whats-new.md) | You want to know what features 2.0 ships and how to use them. |
| [architecture.md](architecture.md) | You want diagrams of the new internals (init flow, read path, push/pull, schema). |
| [breaking-changes.md](breaking-changes.md) | You're touching SDK APIs and need a quick reference for what changed. |
| [schema-migration.md](schema-migration.md) | You manage the database upgrade path or you're debugging a migration. |
| [migrating-from-1.x.md](migrating-from-1.x.md) | You're upgrading an existing 1.x app to 2.0 and want a checklist. |
| [limitations.md](limitations.md) | You hit a wall and want to confirm it's a known limitation. |

---

## Companion documents (in `doc/`)

The release docs above link out to the existing in-depth references:

- [`doc/OFFLINE_FIRST.md`](../OFFLINE_FIRST.md) — offline architecture deep-dive (pull lifecycle, write path, `UnifiedResolver`, `SyncController`, attachments).
- [`doc/OFFLINE_MODE_TOGGLE.md`](../OFFLINE_MODE_TOGGLE.md) — server-driven offline-mode flag, integration patterns, online↔offline transitions.
- [`doc/SETUP.md`](../SETUP.md) — installation, configuration, quick start, app-status guard.
- [`doc/FIELD_CHANGE_HANDLER.md`](../FIELD_CHANGE_HANDLER.md), [`doc/LINK_FILTER_BUILDER.md`](../LINK_FILTER_BUILDER.md), [`doc/FIELD_TYPES.md`](../FIELD_TYPES.md) — form-pipeline references.

---

## Server-side prerequisites

`2.0.0` requires the companion **Frappe Mobile Control** server app at version 1.x or later, which adds the `offline_enabled` Check field to `Mobile Configuration` and surfaces it on the login response.

Server repo: <https://github.com/dhwani-ris/frappe-mobile-control>

Install:

```bash
cd /path/to/frappe-bench
bench get-app https://github.com/dhwani-ris/frappe-mobile-control
bench install-app frappe-mobile-control
bench migrate
```

See [migrating-from-1.x.md → Server prerequisites](migrating-from-1.x.md#1-server-prerequisites) for the rollout order (server first, then SDK).

---

## Versioning

| Component | Version |
|---|---|
| `frappe_mobile_sdk` (Dart package) | `2.0.0` |
| Internal SQLite schema | `3` (`AppDatabase._version`) |
| Required server app | `frappe-mobile-control` ≥ `1.0.0` (with `offline_enabled` field) |

Downgrade is not supported — `sqflite` does not provide a downgrade hook, and `frappe_mobile_sdk` does not retain a v3 → v2 reverse migration.

---

## Status

`2.0.0` is currently **`Unreleased`**. This documentation reflects the shipped surface; release date is appended to the `CHANGELOG.md` entry on tag.
