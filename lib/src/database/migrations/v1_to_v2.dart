import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../models/doc_type_meta.dart';
import '../../models/doc_field.dart';
import '../../models/outbox_row.dart';
import '../schema_applier.dart';
import '../table_name.dart';

class MetaNotFoundException implements Exception {
  final String doctype;
  MetaNotFoundException(this.doctype);
  @override
  String toString() => 'MetaNotFoundException: $doctype';
}

typedef MetaFetcher = Future<DocTypeMeta> Function(String doctype);

class V1ToV2Migration {
  final Database db;
  final MetaFetcher metaFetcher;

  V1ToV2Migration({required this.db, required this.metaFetcher});

  /// Returns true if migration ran, false if skipped (already on v2).
  Future<bool> run() async {
    final current = await _readSchemaVersion();
    if (current >= 2) return false;

    await db.execute('''
      CREATE TABLE IF NOT EXISTS documents__orphaned_v1 (
        localId TEXT PRIMARY KEY,
        doctype TEXT NOT NULL,
        serverId TEXT,
        dataJson TEXT NOT NULL,
        status TEXT NOT NULL,
        modified INTEGER,
        reason TEXT
      )
    ''');

    final doctypes = (await db.rawQuery(
      'SELECT DISTINCT doctype FROM documents',
    )).map((r) => r['doctype'] as String).toList();

    for (final dt in doctypes) {
      DocTypeMeta meta;
      try {
        meta = await metaFetcher(dt);
      } on MetaNotFoundException {
        await _orphanAllForDoctype(dt, reason: 'meta_not_found');
        continue;
      }

      await db.insert(
        'doctype_meta',
        <String, Object?>{
          'doctype': dt,
          'metaJson': jsonEncode(meta.toJson()),
          'isMobileForm': 0,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

      await SchemaApplier.apply(db, meta, isChildTable: false);

      final childDoctypes = <String>{};
      for (final f in meta.fields) {
        if (f.fieldtype == 'Table' || f.fieldtype == 'Table MultiSelect') {
          if (f.options != null && f.options!.isNotEmpty) {
            childDoctypes.add(f.options!);
          }
        }
      }
      for (final childDt in childDoctypes) {
        DocTypeMeta childMeta;
        try {
          childMeta = await metaFetcher(childDt);
        } on MetaNotFoundException {
          continue;
        }
        await db.insert(
          'doctype_meta',
          <String, Object?>{
            'doctype': childDt,
            'metaJson': jsonEncode(childMeta.toJson()),
            'isMobileForm': 0,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        await SchemaApplier.apply(db, childMeta, isChildTable: true);
      }

      await db.transaction((txn) async {
        final rows = await txn.query(
          'documents',
          where: 'doctype = ?',
          whereArgs: [dt],
        );
        final tableName = normalizeDoctypeTableName(dt);

        for (final r in rows) {
          final localId = r['localId'] as String;
          final status = r['status'] as String;
          final serverId = r['serverId'] as String?;
          final modified = r['modified'] as int?;
          final jsonStr = r['dataJson'] as String;

          Map<String, dynamic> parsed;
          try {
            parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
          } catch (_) {
            await txn.insert('documents__orphaned_v1', {
              ...r,
              'reason': 'corrupt_json',
            });
            continue;
          }

          final childTables = <String, List<Map<String, dynamic>>>{};
          final parentFields = <String, Object?>{};
          for (final entry in parsed.entries) {
            final fieldMeta = _fieldByName(meta, entry.key);
            if (fieldMeta?.fieldtype == 'Table' ||
                fieldMeta?.fieldtype == 'Table MultiSelect') {
              final list = (entry.value as List?)
                      ?.map((e) => Map<String, dynamic>.from(e as Map))
                      .toList() ??
                  const <Map<String, dynamic>>[];
              childTables[entry.key] = list;
            } else if (_isPersistable(fieldMeta)) {
              parentFields[entry.key] = entry.value;
            }
          }

          final syncStatus = (status == 'dirty' || status == 'deleted')
              ? 'dirty'
              : 'synced';
          final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;

          final parentRow = <String, Object?>{
            'mobile_uuid': localId,
            'server_name': serverId,
            'sync_status': syncStatus,
            'sync_attempts': 0,
            'docstatus': (parsed['docstatus'] as num?)?.toInt() ?? 0,
            'modified': modified == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(modified, isUtc: true)
                    .toIso8601String(),
            'local_modified': nowMs,
            'pulled_at': status == 'clean' ? nowMs : null,
            ...parentFields,
          };

          for (final f in meta.fields) {
            if ((f.fieldtype == 'Link' || f.fieldtype == 'Dynamic Link') &&
                f.fieldname != null) {
              parentRow['${f.fieldname}__is_local'] = 0;
            }
          }

          await txn.insert(
            tableName,
            parentRow,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );

          for (final entry in childTables.entries) {
            final childField = entry.key;
            final childFieldMeta = _fieldByName(meta, childField);
            final childDt = childFieldMeta?.options;
            if (childDt == null) continue;

            final childTableName = normalizeDoctypeTableName(childDt);
            var idx = 0;
            for (final cr in entry.value) {
              final childRow = <String, Object?>{
                'mobile_uuid': const Uuid().v4(),
                'server_name': cr['name'] as String?,
                'parent_uuid': localId,
                'parent_doctype': dt,
                'parentfield': childField,
                'idx': idx++,
                'modified': null,
              };
              cr.forEach((k, v) {
                if (k == 'name' ||
                    k == 'parent' ||
                    k == 'parenttype' ||
                    k == 'parentfield' ||
                    k == 'idx') {
                  return;
                }
                childRow[k] = v;
              });
              try {
                await txn.insert(childTableName, childRow);
              } catch (_) {
                // child table may not exist if meta was missing; continue.
              }
            }
          }

          if (status == 'dirty' || status == 'deleted') {
            final createdAtMs = (modified ?? nowMs ~/ 1000) * 1000;

            Future<void> enqueue(OutboxOperation op, int orderBump) async {
              await txn.insert('outbox', <String, Object?>{
                'doctype': dt,
                'mobile_uuid': localId,
                'server_name': serverId,
                'operation': op.wireName,
                'payload': jsonStr,
                'state': OutboxState.pending.wireName,
                'retry_count': 0,
                // Bump created_at so the SUBMIT/CANCEL row is dispatched after
                // the INSERT/UPDATE for the same mobile_uuid.
                'created_at': createdAtMs + orderBump,
              });
            }

            if (status == 'deleted') {
              await enqueue(OutboxOperation.delete, 0);
            } else {
              // dirty path
              final op = serverId == null
                  ? OutboxOperation.insert
                  : OutboxOperation.update;
              await enqueue(op, 0);

              // Spec §12.1 docstatus transition rule:
              //   docstatus=1 (Submitted) → enqueue an additional SUBMIT
              //   docstatus=2 (Cancelled) → enqueue an additional CANCEL
              final localDocstatus =
                  (parsed['docstatus'] as num?)?.toInt() ?? 0;
              if (localDocstatus == 1) {
                await enqueue(OutboxOperation.submit, 1);
              } else if (localDocstatus == 2) {
                await enqueue(OutboxOperation.cancel, 1);
              }
            }
          }
        }
      });
    }

    await db.execute(
      'ALTER TABLE documents RENAME TO documents__archived_v1',
    );
    await db.update('sdk_meta', {'schema_version': 2}, where: 'id=1');
    return true;
  }

  Future<int> _readSchemaVersion() async {
    final rows = await db.rawQuery(
      'SELECT schema_version FROM sdk_meta WHERE id=1 LIMIT 1',
    );
    if (rows.isEmpty) return 0;
    return (rows.first['schema_version'] as int?) ?? 0;
  }

  Future<void> _orphanAllForDoctype(
    String doctype, {
    required String reason,
  }) async {
    await db.rawInsert(
      '''
      INSERT INTO documents__orphaned_v1 (
        localId, doctype, serverId, dataJson, status, modified, reason
      )
      SELECT localId, doctype, serverId, dataJson, status, modified, ?
        FROM documents
        WHERE doctype = ?
      ''',
      [reason, doctype],
    );
    await db.delete('documents', where: 'doctype = ?', whereArgs: [doctype]);
  }

  static DocField? _fieldByName(DocTypeMeta meta, String name) {
    for (final f in meta.fields) {
      if (f.fieldname == name) return f;
    }
    return null;
  }

  static bool _isPersistable(DocField? f) {
    if (f == null) return false;
    return !const {
      'Section Break',
      'Column Break',
      'Tab Break',
      'Heading',
      'Button',
    }.contains(f.fieldtype);
  }
}
