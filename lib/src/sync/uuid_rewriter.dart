import '../models/doc_field.dart';
import '../models/doc_type_meta.dart';
import 'push_error.dart';

typedef ResolveServerNameFn = Future<String?> Function(
  String doctype,
  String mobileUuid,
);

/// Substitutes local `mobile_uuid` Link values with server names. Spec §5.2.
///
/// Walks the parent payload + every nested child row. For each Link or
/// Dynamic Link field where `<field>__is_local == 1`:
///   1. Determine the target doctype:
///      - `Link` → from `field.options` (static).
///      - `Dynamic Link` → look up the sibling field named by
///        `field.options` (its value is the runtime target doctype).
///   2. Call [ResolveServerNameFn] (typically a `DoctypeDao` lookup) to
///      get the target's `server_name`.
///   3. Replace the local UUID with the server name.
///   4. Drop the `__is_local` companion key from the outbound payload.
///
/// If a local target can't be resolved (i.e., the parent insert hasn't
/// landed yet), throws [BlockedByUpstream] so the engine can flip the
/// outbox row to `blocked` and retry once the parent succeeds.
class UuidRewriter {
  static Future<Map<String, Object?>> rewrite({
    required DocTypeMeta meta,
    required Map<String, Object?> payload,
    required ResolveServerNameFn resolveServerName,
    Map<String, DocTypeMeta> childMetasByFieldname = const {},
  }) async {
    final out = <String, Object?>{};
    final fieldByName = <String, DocField>{};
    for (final f in meta.fields) {
      if (f.fieldname != null) fieldByName[f.fieldname!] = f;
    }

    for (final entry in payload.entries) {
      final key = entry.key;
      if (key.endsWith('__is_local')) continue;

      final value = entry.value;
      final field = fieldByName[key];

      if (field != null &&
          (field.fieldtype == 'Table' ||
              field.fieldtype == 'Table MultiSelect')) {
        final childMeta = childMetasByFieldname[key];
        if (childMeta == null || value is! List) {
          out[key] = value;
          continue;
        }
        final rewrittenList = <Map<String, Object?>>[];
        for (final row in value) {
          final rowMap = Map<String, Object?>.from(row as Map);
          rewrittenList.add(await rewrite(
            meta: childMeta,
            payload: rowMap,
            resolveServerName: resolveServerName,
          ));
        }
        out[key] = rewrittenList;
        continue;
      }

      if (field != null &&
          (field.fieldtype == 'Link' || field.fieldtype == 'Dynamic Link')) {
        final isLocal = (payload['${key}__is_local'] as int?) == 1;
        if (!isLocal || value == null) {
          out[key] = value;
          continue;
        }
        String? targetDoctype;
        if (field.fieldtype == 'Link') {
          targetDoctype = field.options;
        } else {
          // Dynamic Link — `options` names the sibling field that holds
          // the target doctype's name at runtime.
          final siblingFieldname = field.options;
          if (siblingFieldname != null) {
            targetDoctype = payload[siblingFieldname] as String?;
          }
        }
        if (targetDoctype == null || targetDoctype.isEmpty) {
          throw BlockedByUpstream(
            field: key,
            targetDoctype: '*Dynamic*',
            targetUuid: value.toString(),
          );
        }
        final serverName =
            await resolveServerName(targetDoctype, value.toString());
        if (serverName == null) {
          throw BlockedByUpstream(
            field: key,
            targetDoctype: targetDoctype,
            targetUuid: value.toString(),
          );
        }
        out[key] = serverName;
        continue;
      }

      out[key] = value;
    }
    return out;
  }
}
