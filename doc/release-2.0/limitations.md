# Known limitations — `frappe_mobile_sdk` 2.0

This page collects the gotchas, deferred items, and "by design" constraints you should be aware of before adopting 2.0. None of these block the upgrade, but each can surprise you if you don't expect it.

---

## 1. No downgrade path

`sqflite` does not provide an `_onDowngrade` hook in this SDK's setup. Once a device's database moves to schema v3, the SDK cannot move it back to v2. App-store users cannot install an older version of the app over a newer one anyway, so this matches platform behavior.

**Mitigation:** ship a patch release (2.0.x) for any 2.0 issue. Do not plan to revert by republishing 1.x.

---

## 2. No migration telemetry

The v2 → v3 migration does not emit metrics or events. If it succeeds, it returns silently; if it fails, it throws on the next `openDatabase` call.

**Mitigation:** if rollout visibility matters, instrument around `FrappeSDK.initialize()` in your app:

```dart
try {
  await FrappeSDK.initialize(autoRestoreAndSync: true);
  analytics.logEvent('sdk_init_success');
} catch (e, st) {
  analytics.logError('sdk_init_failure', error: e, stack: st);
  rethrow;
}
```

---

## 3. Server flag must precede device upgrade

The `offline_enabled` Check field must exist on the server's `Mobile Configuration` doctype **before** a device runs SDK 2.0 for the first time. If a device upgrades the SDK first, it sees the column default (`false`); if that device has 1.x offline data and the deployment was offline-first, the next launch will trigger `runDrainAndWipe()` and **delete the local mirror**.

**Mitigation:** roll out the server-side `frappe-mobile-control` upgrade first, set the flag, then ship the SDK upgrade. See [Migrating from 1.x §1](migrating-from-1.x.md#1-server-prerequisites).

---

## 4. Token refresh does not refresh the offline-mode flag

Once a session is established, `OAuth2` / API-key / mobile-OTP token refreshes do **not** re-fetch `offline_enabled`. Long-lived sessions stay in their previous mode until the user re-authenticates (full login).

**Mitigation:** if you need to flip an existing user's mode, force a logout. There is no SDK API to "refresh the flag" mid-session — by design, since flipping mid-session would risk user-visible data churn.

---

## 5. `forTesting` defaults to offline

`FrappeSDK.forTesting(...)` defaults `offlineMode` to `enabled: true`. Existing 1.x tests continue to work (1.x's offline path was the default), but tests that need to verify online-only behavior must opt in:

```dart
final sdk = FrappeSDK.forTesting(
  'http://test',
  db,
  offlineMode: const OfflineMode(enabled: false, isPersisted: true),
);
```

**Why:** the offline path is the more complex and more common case; defaulting tests to it catches regressions earlier.

---

## 6. Push order changed: tier > FIFO

Tests asserting strict insertion-order push behavior will fail under `TierComputer` ordering. This is **not** a bug — it's the new contract.

**Mitigation:** rewrite tests to assert **eventual consistency** (all outbox rows reach `synced`) or **tier ordering** (every row's dependencies push before it).

---

## 7. UUID-shaped server names confuse local-vs-remote resolution

Any string matching the v4 UUID shape is treated as a local `mobile_uuid` and resolved from `docs__*` only. If your Frappe site uses an autoname pattern that produces UUID-shaped names (uncommon but possible), Link references will be misclassified.

**Mitigation:** server-side, prefer `autoname=field:mobile_uuid` (the SDK's L1 idempotency assumption) or any prefix-stamped naming series. Don't use raw UUID-shaped autonames.

---

## 8. Children re-inserted on every parent pull (with identity preservation)

When a parent doc is pulled, its children are deleted and re-inserted. Identity is preserved by 3-key match (`server_name → mobile_uuid → position`), but any custom local state attached to a child row outside the standard schema **is wiped**.

**Mitigation:** don't add custom columns to `docs__<child_doctype>` tables. Anything beyond the standard child schema is ephemeral.

---

## 9. Per-doctype tables created on first pull, not at boot

`docs__<doctype>` tables don't exist until the first `pullSync` (or first offline `create`) for that doctype. If your code peeks at the database via `sqflite_common_ffi` or similar before any pull, it won't find the tables.

**Mitigation:** call `OfflineRepository.ensureSchemaForClosure(...)` explicitly if you need the tables in advance, or make any direct-DB introspection tolerant of `no such table` errors.

---

## 10. `pullSync` is a no-op for child doctypes

Calling `pullSync('Sales Invoice Item')` returns `SyncResult.empty()` immediately — no HTTP, no error. Children come embedded in their parent's pull, never standalone.

**Mitigation:** don't call `pullSync` on `istable=1` doctypes. If you do, expect zeros. To fetch a child row, pull its parent.

---

## 11. `LinkFilterBuilder` is keyed on the target doctype

Builders register against the **target** of a Link field, not the owning doctype. This is the opposite of what some users expect.

```dart
// CORRECT
LinkFilterBuilder? filter(String fieldName, String targetDoctype) {
  if (targetDoctype == 'Customer') { ... }
}

// WRONG (won't fire)
LinkFilterBuilder? filter(String fieldName, String targetDoctype) {
  if (targetDoctype == 'Sales Invoice') { ... } // Sales Invoice is the OWNING doctype
}
```

**Mitigation:** when a Link field points from `Sales Invoice` → `Customer`, key the builder on `Customer`. See [`doc/LINK_FILTER_BUILDER.md`](../LINK_FILTER_BUILDER.md).

---

## 12. Public docs other than `release-2.0/`

The other files in `doc/` (`OFFLINE_FIRST.md`, `OFFLINE_MODE_TOGGLE.md`, `FIELD_TYPES.md`, etc.) describe specific subsystems and are referenced from these release docs. They are kept current for 2.0, but they were written **before** this release-doc folder existed and may use slightly different terminology in places. The 2.0 release docs are the canonical entry point; the topical docs are the deep dives.

---

## See also

- [Migrating from 1.x](migrating-from-1.x.md)
- [Breaking changes](breaking-changes.md)
- [Schema migration](schema-migration.md)
- [Architecture](architecture.md)
