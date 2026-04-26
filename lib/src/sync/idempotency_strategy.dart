import '../models/doc_type_meta.dart';

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
  /// `mobile_uuid` field before each retry. Requires the consumer to add
  /// a `mobile_uuid` field on the DocType; otherwise duplicates are
  /// possible on flaky networks (warning emitted at first push).
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
