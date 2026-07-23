// Fix 3 — per-doctype fault isolation in
// `OfflineRepository.ensureSchemaForClosure`.
//
// Before the fix, ONE doctype whose generated CREATE threw (a closure-dragged
// framework doctype) aborted the whole loop, so every doctype AFTER it got no
// table — the observed `no such table: docs__report / docs__country /
// docs__dashboard_chart` collateral. The fix wraps each doctype's schema
// build in try/catch/continue, so a single bad DDL is isolated and its
// siblings' tables are still created.
//
// We provoke a genuine DDL failure with a field name containing an embedded
// double quote, which makes the (correctly-quoted) column identifier
// self-terminate → a hard CREATE TABLE syntax error at execute time. The
// poison sits in the MIDDLE of the closure so we prove BOTH the doctype
// before it and the one after it survive.

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/sqlite_utils.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n) => DocField(fieldname: n, fieldtype: 'Data', label: n);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  setUp(() async => appDb = await AppDatabase.inMemoryDatabase());
  tearDown(() async => appDb.close());

  test(
    'a single doctype whose DDL throws is isolated — sibling tables still created',
    () async {
      final repo = OfflineRepository(appDb);

      // Insertion order matters: Poison sits between two good doctypes.
      final metas = <String, DocTypeMeta>{
        'Alpha': DocTypeMeta(name: 'Alpha', fields: [f('title')]),
        // Embedded double-quote → `"bad"col" TEXT` → CREATE TABLE syntax error.
        'Poison': DocTypeMeta(name: 'Poison', fields: [f('bad"col')]),
        'Beta': DocTypeMeta(name: 'Beta', fields: [f('title')]),
      };

      // Must NOT throw — the loop swallows the poison doctype's failure.
      await repo.ensureSchemaForClosure(
        metas: metas,
        childDoctypes: const <String>{},
      );

      final raw = appDb.rawDatabase;
      expect(
        await sqliteTableExists(raw, 'docs__alpha'),
        isTrue,
        reason: 'the doctype BEFORE the poison must still be created',
      );
      expect(
        await sqliteTableExists(raw, 'docs__beta'),
        isTrue,
        reason: 'the doctype AFTER the poison must still be created — no '
            '`no such table` collateral',
      );
      expect(
        await sqliteTableExists(raw, 'docs__poison'),
        isFalse,
        reason: 'the failing doctype gets no table (retried on the next call)',
      );

      // The surviving sibling table is genuinely usable.
      await raw.insert('docs__beta', {
        'mobile_uuid': 'u-1',
        'local_modified': 1,
        'title': 'ok',
      });
      final rows = await raw.query('docs__beta');
      expect(rows, hasLength(1));
    },
  );
}
