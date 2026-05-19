import 'package:sqflite/sqflite.dart';

/// Returns `true` if a table named [tableName] exists in the SQLite schema.
///
/// Accepts either a [Database] (root connection) or a [Transaction] — both
/// implement [DatabaseExecutor] — so the same helper works inside and outside
/// transactions. Centralized so the `sqlite_master` query string lives in one
/// place; all writers (DDL, form-save, pull-apply, sync) call this instead of
/// inlining the lookup.
Future<bool> sqliteTableExists(DatabaseExecutor exec, String tableName) async {
  final rows = await exec.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
    [tableName],
  );
  return rows.isNotEmpty;
}
