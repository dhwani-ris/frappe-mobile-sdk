# Offline Mode Toggle — Server-Driven Switch

The SDK supports a server-driven switch that turns the offline-first
data layer on or off per deployment. When **off** (the default), the
SDK behaves as a thin online client: meta is still cached locally for
fast form rendering, but every document read and write goes directly
to the Frappe REST API — no `docs__*` tables, no outbox, no closure
pull, no `link_options` cache.

Use it when you have:
- Internal apps where users always have network — you don't need the
  full offline machinery.
- A staged rollout where you want to defer offline-first behavior
  until the server-side is ready.
- A device profile (low storage, kiosk mode) where local mirroring
  isn't desirable.

## How the flag is delivered

The flag lives on the `Mobile Configuration` single doctype as
`offline_enabled` (Check, default `0`). The server includes it in
every authenticated login response under the top-level
`offline_enabled` key. The SDK persists the value to its local
`sdk_meta` table after each successful login. The next call to
`FrappeSDK.initialize()` reads it and wires every service in the
matching mode for the session.

| Auth flow | Persists `offline_enabled`? |
|---|---|
| Username + password (`login`) | Yes |
| Mobile OTP (`verifyLoginOtp`) | Yes |
| API key (`loginWithApiKey`) | Yes (via `mobile_auth.me`) |
| OAuth (`loginWithOAuth`) | Yes (via `mobile_auth.me`) |
| Token refresh | **No** — flag is only refreshed on full login |

A missing `offline_enabled` key in the response is treated as `false`.
Without server-side `mobile_control` upgraded to a version that
emits the field, the SDK will default to online mode.

## Server-side setup

**Required**: install the latest `mobile_control` Frappe app on your
server, then:

1. Open the **Mobile Configuration** single doctype in Desk.
2. Toggle **Enabled** on (existing field).
3. Toggle **Offline Mode Enabled** on if you want offline-first
   behavior for all clients.
4. Save. The next mobile login picks up the new value.

The flag is app-wide — not per-form. If you need per-form control,
that's tracked in the design doc as a future scope item.

## Client-side integration

For most apps no code changes are needed beyond updating to the new
SDK version. The SDK derives the mode from the persisted flag in
`initialize()` and selects the right read / write paths automatically.

If you want users to see the drain/wipe UI when an admin flips the
flag from on to off, wrap your app's home with `OfflineTransitionGuard`:

```dart
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

@override
Widget build(BuildContext context) {
  return MaterialApp(
    home: _sdk == null
        ? const _Splash()
        : OfflineTransitionGuard(
            sdk: _sdk!,
            child: _yourHomeScreen,
          ),
  );
}
```

The guard subscribes to `sdk.offlineTransition.stream` and overlays
`OfflineTransitionScreen` whenever the SDK is mid-transition. The
screen has three views:

- **Draining** — progress indicator while pending records are pushed.
- **Drain failed** — count of remaining records, the last error, and
  two buttons: **Retry** and **Force exit** (with a confirmation
  dialog).
- **Wiping local data** — final cleanup before returning to online mode.

Once `TransitionCompleted` is emitted, the guard transparently shows
your child widget again.

If you'd rather drive the flow yourself, you can subscribe to the
stream directly:

```dart
sdk.offlineTransition.stream.listen((state) {
  switch (state) {
    case TransitionDraining(:final drainedRecords, :final totalRecords):
      // update progress UI
    case TransitionDrainFailed(:final remainingDirty):
      // show your own retry / force-exit UI
    case TransitionCompleted():
      // dismiss
    case _:
      // idle / wiping
  }
});

// Manually re-attempt after a fix:
sdk.offlineTransition.retry();

// Or accept data loss and proceed:
await sdk.offlineTransition.forceExit();
```

## What stays local in online mode

| State | Online mode (`offline_enabled = false`) | Offline mode |
|---|---|---|
| `doctype_meta` | Cached (fast form load) | Cached |
| `auth_tokens` | Cached (session restore) | Cached |
| `doctype_permission` | Cached, refreshed each launch | Cached |
| `sdk_meta` | Used for the offline-mode flag itself | Used |
| `link_options` | Not written | Cached |
| `docs__<doctype>` per-doctype tables | **Not created** | Created |
| `outbox` (pending writes) | **Empty** | Used |
| `pending_attachments` | **Empty** | Used |

In online mode:
- Reads route through `UnifiedResolver._onlinePassthrough` and call
  `frappe.client.get_list` directly.
- Writes call `client.document.createDocument` / `updateDocument` /
  `deleteDocument` directly. Failures propagate to the caller — the
  consumer's UI handles them (no offline retry queue exists).
- `SyncService.pushSync` / `pullSync` / `pullSyncMany` etc. return
  `SyncResult.empty()`. The sync engine is a no-op.
- The closure pull on app start is skipped — only meta, permissions,
  and translations are refreshed.

## Transition: switching offline → online

When an admin flips `offline_enabled` from on to off, existing
deployments will have residual local data: `docs__*` tables, queued
outbox rows, queued attachments. The SDK reconciles this on the next
launch:

1. `FrappeSDK.initialize()` reads the persisted flag (now `false`)
   and detects residue (any `docs__*` table or non-empty outbox or
   non-empty pending attachments).
2. It kicks off `OfflineTransitionService.runDrainAndWipe()` in the
   background — this does **not** block `initialize()` so the widget
   tree mounts immediately and the user sees the transition UI.
3. The service runs `pushSync()` (against a transient SyncService
   wired with offline mode forced on) to drain the outbox and
   pending attachments to the server.
4. **Success** → `wipeOfflineDocumentTables()` drops every `docs__*`
   table and clears `outbox`, `pending_attachments`, `link_options`.
   `auth_tokens`, `doctype_meta`, `doctype_permission`, and `sdk_meta`
   are preserved.
5. **Failure** (network down, server rejection, etc.) → the service
   emits `TransitionDrainFailed`. The user sees the **Retry** and
   **Force exit** buttons. Force exit drops everything
   unconditionally — last-resort recovery.

If the user kills the app mid-transition, the same trigger fires on
the next launch and the flow resumes.

## Transition: switching online → offline

Trivial. The first launch where the flag flips from off to on simply
hits the existing offline boot path: `_initialMetaAndDataSync` runs
the closure pull and per-doctype tables are created lazily. No
explicit transition is needed.

## Schema migration

The SDK ships a v4 → v5 schema migration that adds two columns to
`sdk_meta`:

- `offline_enabled INTEGER NOT NULL DEFAULT 0`
- `offline_enabled_set_at INTEGER` (epoch ms; `NULL` until first login)

The migration is automatic; no consumer action required. Existing
installs upgrade their schema on first launch with the new SDK.

## Testing your integration

`FrappeSDK.forTesting` accepts an explicit `offlineMode` parameter
so widget tests can exercise either path without going through a
real login:

```dart
final db = await AppDatabase.inMemoryDatabase();
final sdk = FrappeSDK.forTesting(
  'http://localhost',
  db,
  offlineMode: const OfflineMode(enabled: false, isPersisted: true),
);
// sdk now treats every read/write as online
```

Default is offline-mode (preserves the behavior expected by tests
written against earlier SDK versions).

## Limitations

- **Token refresh does not refresh the flag.** Long-lived OAuth /
  API-key sessions stay in their previous mode until the user goes
  through a full login again. Admins can force a re-auth by
  invalidating `Mobile Refresh Token` records.
- **OS-level recents-swipe cannot be blocked.** The transition
  screen's `PopScope` blocks the back button, but if the user swipes
  the app away from the recents menu the OS kills the process. The
  transition resumes on next launch (drain state is in the local DB,
  not in memory).
- **Old server + new SDK.** If you ship the new SDK to clients before
  upgrading `mobile_control`, the login response will lack the
  `offline_enabled` key and the SDK will persist `false` for any
  user who logs in. Deploy the server side first.

## Files in the SDK

| Path | Purpose |
|---|---|
| `lib/src/models/offline_mode.dart` | `OfflineMode` value object |
| `lib/src/database/daos/sdk_meta_dao.dart` | Read/write the flag on `sdk_meta` |
| `lib/src/services/offline_transition_service.dart` | State stream + drain/wipe orchestration |
| `lib/src/ui/offline_transition_screen.dart` | Drain progress + retry / force-exit UI |
| `lib/src/ui/offline_transition_guard.dart` | Stream-driven wrapper widget |
| `lib/src/sdk/frappe_sdk.dart` | Boot mode resolution + `_persistOfflineFlagFromLogin` + `offlineTransition` getter |

## Related docs

- [`OFFLINE_FIRST.md`](OFFLINE_FIRST.md) — the offline-first data
  layer the toggle gates.
- [`SETUP.md`](SETUP.md) — first-time integration guide.
