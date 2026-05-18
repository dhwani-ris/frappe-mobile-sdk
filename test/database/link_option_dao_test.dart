import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/link_option_dao.dart';
import 'package:frappe_mobile_sdk/src/database/entities/link_option_entity.dart';

LinkOptionEntity _opt({
  int? id,
  String doctype = 'State',
  String name = 'Tamil Nadu',
  String? label,
  int lastUpdated = 1,
}) => LinkOptionEntity(
  id: id,
  doctype: doctype,
  name: name,
  label: label,
  lastUpdated: lastUpdated,
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('insert + read', () {
    test('insertLinkOption persists a row and findAll returns it', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final dao = LinkOptionDao(db.rawDatabase);

      await dao.insertLinkOption(_opt(label: 'TN'));
      final all = await dao.findAll();
      expect(all, hasLength(1));
      expect(all.single.doctype, 'State');
      expect(all.single.name, 'Tamil Nadu');
      expect(all.single.label, 'TN');
      expect(all.single.id, isNotNull);
      await db.close();
    });

    test('insertLinkOptions batch persists all rows', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final dao = LinkOptionDao(db.rawDatabase);

      await dao.insertLinkOptions([
        _opt(name: 'TN'),
        _opt(name: 'KL'),
        _opt(name: 'KA'),
      ]);
      expect(await dao.findAll(), hasLength(3));
      await db.close();
    });

    test('insertLinkOptions on empty list is a no-op', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final dao = LinkOptionDao(db.rawDatabase);
      await dao.insertLinkOptions([]);
      expect(await dao.findAll(), isEmpty);
      await db.close();
    });
  });

  group('findByDoctype', () {
    test('filters by doctype and orders by lastUpdated DESC', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final dao = LinkOptionDao(db.rawDatabase);

      await dao.insertLinkOptions([
        _opt(doctype: 'State', name: 'TN', lastUpdated: 100),
        _opt(doctype: 'State', name: 'KL', lastUpdated: 300),
        _opt(doctype: 'State', name: 'KA', lastUpdated: 200),
        _opt(doctype: 'District', name: 'Chennai', lastUpdated: 50),
      ]);

      final states = await dao.findByDoctype('State');
      expect(states.map((s) => s.name).toList(), ['KL', 'KA', 'TN']);

      final districts = await dao.findByDoctype('District');
      expect(districts, hasLength(1));
      expect(districts.single.name, 'Chennai');
      await db.close();
    });

    test('returns empty list for unknown doctype', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final dao = LinkOptionDao(db.rawDatabase);
      expect(await dao.findByDoctype('Nothing'), isEmpty);
      await db.close();
    });
  });

  group('update', () {
    test('updateLinkOption replaces a row in place', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final dao = LinkOptionDao(db.rawDatabase);
      await dao.insertLinkOption(_opt(name: 'TN', label: 'Tamil Nadu'));
      final stored = (await dao.findAll()).single;

      await dao.updateLinkOption(
        LinkOptionEntity(
          id: stored.id,
          doctype: stored.doctype,
          name: stored.name,
          label: 'Tamil Nadu (renamed)',
          lastUpdated: 999,
        ),
      );

      final after = (await dao.findAll()).single;
      expect(after.label, 'Tamil Nadu (renamed)');
      expect(after.lastUpdated, 999);
      await db.close();
    });

    test('updateLinkOption throws when id is null', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final dao = LinkOptionDao(db.rawDatabase);
      expect(() => dao.updateLinkOption(_opt()), throwsA(isA<Exception>()));
      await db.close();
    });
  });

  group('delete', () {
    test('deleteLinkOption removes a single row', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final dao = LinkOptionDao(db.rawDatabase);
      await dao.insertLinkOptions([_opt(name: 'TN'), _opt(name: 'KL')]);
      final all = await dao.findAll();
      await dao.deleteLinkOption(all.first);

      expect(await dao.findAll(), hasLength(1));
      await db.close();
    });

    test('deleteLinkOption throws when id is null', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final dao = LinkOptionDao(db.rawDatabase);
      expect(() => dao.deleteLinkOption(_opt()), throwsA(isA<Exception>()));
      await db.close();
    });

    test('deleteByDoctype clears only that doctype', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final dao = LinkOptionDao(db.rawDatabase);
      await dao.insertLinkOptions([
        _opt(doctype: 'State', name: 'TN'),
        _opt(doctype: 'State', name: 'KL'),
        _opt(doctype: 'District', name: 'Chennai'),
      ]);

      await dao.deleteByDoctype('State');

      expect(await dao.findByDoctype('State'), isEmpty);
      expect(await dao.findByDoctype('District'), hasLength(1));
      await db.close();
    });

    test('deleteAll clears the table', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final dao = LinkOptionDao(db.rawDatabase);
      await dao.insertLinkOptions([
        _opt(doctype: 'A', name: 'a'),
        _opt(doctype: 'B', name: 'b'),
      ]);

      await dao.deleteAll();

      expect(await dao.findAll(), isEmpty);
      await db.close();
    });
  });

  test(
    'batch insert with same (doctype, name) replaces by primary key, not natural key',
    () async {
      // SQLite ConflictAlgorithm.replace acts on PRIMARY KEY conflicts. Since
      // `link_options` PK is `id AUTOINCREMENT` with no UNIQUE on (doctype, name),
      // inserting the same logical option twice yields TWO rows, not one. This
      // pins that behavior so a future migration adding UNIQUE doesn't silently
      // change the contract.
      final db = await AppDatabase.inMemoryDatabase();
      final dao = LinkOptionDao(db.rawDatabase);

      await dao.insertLinkOption(
        _opt(doctype: 'State', name: 'TN', label: 'v1'),
      );
      await dao.insertLinkOption(
        _opt(doctype: 'State', name: 'TN', label: 'v2'),
      );

      final rows = await dao.findByDoctype('State');
      expect(
        rows,
        hasLength(2),
        reason:
            'no UNIQUE constraint → both rows persist with auto-generated ids',
      );
      await db.close();
    },
  );
}
