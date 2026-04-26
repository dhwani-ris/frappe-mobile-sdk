import 'package:sqflite/sqflite.dart';
import '../models/doc_type_meta.dart';
import 'schema/parent_schema.dart';
import 'schema/child_schema.dart';
import 'table_name.dart';

class SchemaApplier {
  /// Applies the DDL for a single doctype — parent OR child table.
  /// Runs inside a transaction. Idempotent (skips if the table already exists).
  /// Updates doctype_meta.table_name + is_child_table on success.
  static Future<void> apply(
    Database db,
    DocTypeMeta meta, {
    required bool isChildTable,
    int maxIndexes = 7,
    Map<String, int>? linkEdgeCount,
  }) async {
    final tableName = normalizeDoctypeTableName(meta.name);

    await db.transaction((txn) async {
      final existing = await txn.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = ? LIMIT 1",
        [tableName],
      );
      if (existing.isEmpty) {
        final ddl = isChildTable
            ? buildChildSchemaDDL(meta, tableName: tableName)
            : buildParentSchemaDDL(
                meta,
                tableName: tableName,
                maxIndexes: maxIndexes,
                linkEdgeCount: linkEdgeCount,
              );
        for (final stmt in ddl) {
          await txn.execute(stmt);
        }
      }

      await txn.update(
        'doctype_meta',
        <String, Object?>{
          'table_name': tableName,
          'is_child_table': isChildTable ? 1 : 0,
        },
        where: 'doctype = ?',
        whereArgs: [meta.name],
      );
    });
  }
}
