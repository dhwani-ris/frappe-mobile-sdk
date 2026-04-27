import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late DoctypeMetaDao dao;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    // Create doctype_meta in its current shape (matches AppDatabase._onCreate).
    await db.execute('''
      CREATE TABLE doctype_meta (
        doctype TEXT PRIMARY KEY,
        modified TEXT,
        serverModifiedAt TEXT,
        isMobileForm INTEGER NOT NULL DEFAULT 0,
        metaJson TEXT NOT NULL,
        groupName TEXT,
        sortOrder INTEGER
      )
    ''');
    for (final stmt in doctypeMetaExtensionsDDL()) {
      await db.execute(stmt);
    }
    dao = DoctypeMetaDao(db);
  });

  tearDown(() async => db.close());

  test('setTableName + getTableName round trip', () async {
    await db.insert('doctype_meta', {
      'doctype': 'Sales Order',
      'metaJson': '{}',
    });
    await dao.setTableName('Sales Order', 'docs__sales_order');
    expect(await dao.getTableName('Sales Order'), 'docs__sales_order');
  });

  test('setDepGraphJson + getDepGraphJson', () async {
    await db.insert('doctype_meta', {
      'doctype': 'X',
      'metaJson': '{}',
    });
    await dao.setDepGraphJson('X', '{"nodes":[]}');
    expect(await dao.getDepGraphJson('X'), '{"nodes":[]}');
  });

  test('setLastOkCursor + getLastOkCursor', () async {
    await db.insert('doctype_meta', {
      'doctype': 'X',
      'metaJson': '{}',
    });
    await dao.setLastOkCursor(
      'X',
      '{"modified":"2026-01-01 00:00:00","name":"A"}',
    );
    expect(
      await dao.getLastOkCursor('X'),
      '{"modified":"2026-01-01 00:00:00","name":"A"}',
    );
  });

  test('markEntryPoint sets is_entry_point=1', () async {
    await db.insert('doctype_meta', {
      'doctype': 'X',
      'metaJson': '{}',
    });
    await dao.markEntryPoint('X', true);
    final rows = await db.query(
      'doctype_meta',
      where: 'doctype=?',
      whereArgs: ['X'],
    );
    expect(rows.first['is_entry_point'], 1);
  });

  test('setMetaWatermark + getMetaWatermark', () async {
    await db.insert('doctype_meta', {
      'doctype': 'X',
      'metaJson': '{}',
    });
    await dao.setMetaWatermark('X', '2026-04-25 12:00:00');
    expect(await dao.getMetaWatermark('X'), '2026-04-25 12:00:00');
  });

  test('markChildTable sets is_child_table=1', () async {
    await db.insert('doctype_meta', {
      'doctype': 'X',
      'metaJson': '{}',
    });
    await dao.markChildTable('X', true);
    final rows = await db.query(
      'doctype_meta',
      where: 'doctype=?',
      whereArgs: ['X'],
    );
    expect(rows.first['is_child_table'], 1);
  });
}
