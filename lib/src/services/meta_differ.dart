import '../database/field_type_mapping.dart';
import '../database/table_name.dart';
import '../models/doc_type_meta.dart';
import '../models/doc_field.dart';
import '../models/meta_diff.dart';

class MetaDiffer {
  static MetaDiff diff({
    required DocTypeMeta oldMeta,
    required DocTypeMeta newMeta,
  }) {
    final oldByName = _fieldMap(oldMeta);
    final newByName = _fieldMap(newMeta);

    final added = <AddedField>[];
    final removed = <String>[];
    final typeChanged = <String>[];
    final addedIsLocal = <String>[];
    final indexesToDrop = <String>[];

    for (final entry in newByName.entries) {
      final name = entry.key;
      final f = entry.value;
      final type = f.fieldtype;
      final sqlType = sqliteColumnTypeFor(type);
      if (sqlType == null) continue;

      if (!oldByName.containsKey(name)) {
        added.add(AddedField(name: name, sqlType: sqlType));
        if (isLinkFieldType(type)) addedIsLocal.add(name);
      } else {
        final oldType = oldByName[name]!.fieldtype;
        if (oldType != type) {
          typeChanged.add(name);
        }
      }
    }

    final newTableSuffix =
        normalizeDoctypeTableName(newMeta.name).replaceFirst('docs__', '');
    for (final name in oldByName.keys) {
      final oldFt = oldByName[name]!.fieldtype;
      if (sqliteColumnTypeFor(oldFt) == null) continue;
      if (!newByName.containsKey(name)) {
        removed.add(name);
        // Conservative: drop any index that follows our own ix_<suffix>_<col>
        // naming scheme. MetaMigration tolerates "index doesn't exist".
        indexesToDrop.add('ix_${newTableSuffix}_$name');
      }
    }

    final oldNormSet = _normFieldSet(oldMeta);
    final newNormSet = _normFieldSet(newMeta);
    final addedNorm = <String>[];
    for (final sf in newNormSet.difference(oldNormSet)) {
      final f = newByName[sf];
      if (f != null && sqliteColumnTypeFor(f.fieldtype) == 'TEXT') {
        addedNorm.add(sf);
      }
    }

    return MetaDiff(
      doctype: newMeta.name,
      addedFields: added,
      removedFields: removed,
      typeChanged: typeChanged,
      addedIsLocalFor: addedIsLocal,
      addedNormFor: addedNorm,
      indexesToDrop: indexesToDrop,
    );
  }

  static Map<String, DocField> _fieldMap(DocTypeMeta m) {
    final out = <String, DocField>{};
    for (final f in m.fields) {
      if (f.fieldname != null) out[f.fieldname!] = f;
    }
    return out;
  }

  static Set<String> _normFieldSet(DocTypeMeta m) {
    final s = <String>{};
    if (m.titleField != null) s.add(m.titleField!);
    for (final sf in (m.searchFields ?? const <String>[])) {
      s.add(sf);
    }
    return s;
  }
}
