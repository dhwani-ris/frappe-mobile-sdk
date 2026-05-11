import '../models/doc_type_meta.dart';

/// Per-DocType strategy for surviving INSERT retries without duplicating
/// rows server-side. Picked once per session per DocType by
/// [IdempotencyStrategy.pick]; the choice depends on what the consumer
/// Frappe deployment can guarantee.
///
/// ## Picking order (best → worst)
///
/// 1. **[userSetNaming] (L1)** — strongest. Name *is* `mobile_uuid`; any
///    retry of the same INSERT collides on the unique `name` column and
///    Frappe returns `DuplicateEntryError`, which the SDK treats as
///    "already landed, reconcile". Zero extra round-trips. **No new field
///    needed.** Requires server-side `autoname = "field:mobile_uuid"`.
/// 2. **[serverDedupHook] (L2)** — same guarantee as L1 but without
///    changing `autoname`. Consumer's `mobile_control` Frappe app installs
///    a `before_insert` hook that raises `DuplicateEntryError` when a row
///    with the requested `mobile_uuid` already exists. Detected at login
///    via the `X-Mobile-Essentials-Version` response header.
/// 3. **[preRetryGetCheck] (L3)** — last-resort. Vanilla Frappe with no
///    consumer hook. Before each retry the SDK does a GET keyed on the
///    DocType's `mobile_uuid` field; if the row already exists, treat as
///    success. **REQUIRES** a `mobile_uuid` *field* on the DocType (a
///    custom field is fine). If the field is missing, L3 cannot detect a
///    landed-but-unacked INSERT and a flaky network can produce duplicate
///    rows — [IdempotencyStrategy.pick] fires `onInitWarning` exactly once
///    per such DocType to surface this.
///
/// ## Deployment guidance
///
/// If you cannot add a `mobile_uuid` field on every DocType, prefer L1
/// (`autoname = field:mobile_uuid`) or L2 (install `mobile_control`'s
/// `before_insert` hook) instead of relying on L3 — both are stronger and
/// neither needs a field.
enum IdempotencyLevel {
  /// L1 — `autoname = field:mobile_uuid` on the server. Name == mobile_uuid;
  /// retried POST returns DuplicateEntryError → SDK fetches existing doc
  /// and writes back. Zero extra round-trips. Spec §5.7.
  userSetNaming,

  /// L2 — consumer Frappe app installs a `before_insert` doc_event hook
  /// that raises `DuplicateEntryError` when a row with the given
  /// mobile_uuid already exists. Detected via the
  /// `X-Mobile-Essentials-Version` response header.
  serverDedupHook,

  /// L3 — vanilla Frappe. SDK does an extra GET keyed on the doctype's
  /// `mobile_uuid` field before each retry.
  ///
  /// **Lost-ACK protection is only available if the DocType has a
  /// `mobile_uuid` field** (added as a custom field is fine). Without it,
  /// the GET cannot find a landed row and retries on flaky networks may
  /// produce duplicates. [IdempotencyStrategy.pick] emits a one-shot
  /// `onInitWarning` for any L3 DocType missing the field.
  ///
  /// Prefer L1 (`autoname = field:mobile_uuid`) or L2 (`mobile_control`
  /// `before_insert` hook) for deployments where adding a `mobile_uuid`
  /// field on every DocType isn't an option — both give stronger
  /// guarantees and need no schema change on the target DocType.
  preRetryGetCheck,
}

class IdempotencyDecision {
  final IdempotencyLevel level;
  final bool hasMobileUuidField;

  const IdempotencyDecision({
    required this.level,
    required this.hasMobileUuidField,
  });
}

typedef InitWarningCallback = void Function(String message);

/// Picks the right idempotency strategy per DocType per session and
/// caches the decision so per-doctype init warnings fire exactly once.
class IdempotencyStrategy {
  /// True if the `X-Mobile-Essentials-Version` header was advertised on
  /// login — indicates the consumer Frappe app's `before_insert` dedup
  /// hook is installed.
  final bool serverHasDedupHook;

  /// Override that bypasses auto-detection (e.g. consumer SDKConfig).
  final IdempotencyLevel? override;

  /// One-time warning callback for L3 doctypes lacking a `mobile_uuid`
  /// field — duplication is possible on retry.
  final InitWarningCallback? onInitWarning;

  final Map<String, IdempotencyDecision> _cache = {};

  IdempotencyStrategy({
    required this.serverHasDedupHook,
    this.override,
    this.onInitWarning,
  });

  IdempotencyDecision pick(DocTypeMeta meta) {
    final cached = _cache[meta.name];
    if (cached != null) return cached;

    final hasMobileUuidField = _hasMobileUuidField(meta);
    IdempotencyLevel level;

    if (override != null) {
      level = override!;
    } else if (meta.autoname == 'field:mobile_uuid') {
      level = IdempotencyLevel.userSetNaming;
    } else if (serverHasDedupHook) {
      level = IdempotencyLevel.serverDedupHook;
    } else {
      level = IdempotencyLevel.preRetryGetCheck;
      if (!hasMobileUuidField && onInitWarning != null) {
        onInitWarning!(
          'DocType "${meta.name}": no autoname=field:mobile_uuid, no server '
          'dedup hook, and no mobile_uuid field — INSERT retries may '
          'duplicate on flaky networks. Add one of: '
          '(a) autoname=field:mobile_uuid, '
          '(b) consumer before_insert dedup hook, or '
          '(c) a queryable mobile_uuid custom field.',
        );
      }
    }

    final decision = IdempotencyDecision(
      level: level,
      hasMobileUuidField: hasMobileUuidField,
    );
    _cache[meta.name] = decision;
    return decision;
  }

  static bool _hasMobileUuidField(DocTypeMeta meta) {
    for (final f in meta.fields) {
      if (f.fieldname == 'mobile_uuid') return true;
    }
    return false;
  }
}
