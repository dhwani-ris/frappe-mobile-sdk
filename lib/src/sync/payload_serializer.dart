import '../database/schema/system_columns.dart';
import '../models/doc_type_meta.dart';

/// Serializes a `docs__<doctype>` row into the canonical user-fields-only
/// shape used by [ThreeWayMerge] base snapshots and by [PayloadAssembler]
/// when assembling outbound payloads.
///
/// Drops SDK-internal sync metadata, transient bookkeeping columns, and
/// the `*__norm` / `*__is_local` companion columns. KEEPS `docstatus`
/// and `modified` because Frappe needs both on UPDATE/SUBMIT/CANCEL.
/// KEEPS every user field declared on [meta].
///
/// The result is suitable both as a `ThreeWayMerge.mergeFields` `base`
/// and as the parent-field portion of a Frappe payload, so the merge
/// base and the eventual push body are byte-comparable.
class PayloadSerializer {
  /// Columns excluded from outbound payloads. Sourced from the shared
  /// [systemSyncMetadataColumnNames] so this strip-decision and the one
  /// in `PayloadAssembler` cannot drift apart.
  ///
  /// Note: `docstatus` and `modified` are NOT in this set — they are
  /// genuine Frappe doc fields that the server expects on the wire.
  static const _excludedColumns = systemSyncMetadataColumnNames;

  static Map<String, Object?> serializeForBase(
    Map<String, Object?> row,
    DocTypeMeta meta,
  ) {
    final out = <String, Object?>{};
    for (final entry in row.entries) {
      final key = entry.key;
      if (_excludedColumns.contains(key)) continue;
      if (key.endsWith('__norm')) continue;
      if (key.endsWith('__is_local')) continue;
      out[key] = entry.value;
    }
    return out;
  }
}
