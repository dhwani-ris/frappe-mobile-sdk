import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_permission_dao.dart';
import 'package:frappe_mobile_sdk/src/database/entities/doctype_permission_entity.dart';

DoctypePermissionEntity _perm({
  String doctype = 'Customer',
  bool read = true,
  bool write = false,
  bool create = false,
  bool delete = false,
  bool submit = false,
  bool cancel = false,
  bool amend = false,
}) => DoctypePermissionEntity(
  doctype: doctype,
  read: read,
  write: write,
  create: create,
  delete: delete,
  submit: submit,
  cancel: cancel,
  amend: amend,
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('findByDoctype returns null when no row exists', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final dao = DoctypePermissionDao(db.rawDatabase);
    expect(await dao.findByDoctype('Customer'), isNull);
    await db.close();
  });

  test('upsert persists and findByDoctype round-trips all flags', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final dao = DoctypePermissionDao(db.rawDatabase);
    await dao.upsert(
      _perm(
        doctype: 'Sales Invoice',
        read: true,
        write: true,
        create: true,
        delete: false,
        submit: true,
        cancel: true,
        amend: false,
      ),
    );

    final p = await dao.findByDoctype('Sales Invoice');
    expect(p, isNotNull);
    expect(p!.read, isTrue);
    expect(p.write, isTrue);
    expect(p.create, isTrue);
    expect(p.delete, isFalse);
    expect(p.submit, isTrue);
    expect(p.cancel, isTrue);
    expect(p.amend, isFalse);
    await db.close();
  });

  test('upsert on existing doctype replaces the row (PK = doctype)', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final dao = DoctypePermissionDao(db.rawDatabase);
    await dao.upsert(_perm(doctype: 'Lead', read: true, write: false));
    await dao.upsert(_perm(doctype: 'Lead', read: true, write: true));

    final rows = await db.rawDatabase.query('doctype_permission');
    expect(rows, hasLength(1), reason: 'PK conflict on doctype must replace');
    final p = await dao.findByDoctype('Lead');
    expect(p!.write, isTrue);
    await db.close();
  });

  test('upsertAll persists each entity', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final dao = DoctypePermissionDao(db.rawDatabase);
    await dao.upsertAll([
      _perm(doctype: 'Customer', read: true),
      _perm(doctype: 'Supplier', read: true, write: true),
      _perm(doctype: 'Item', read: true, create: true),
    ]);

    expect((await dao.findByDoctype('Customer'))!.read, isTrue);
    expect((await dao.findByDoctype('Supplier'))!.write, isTrue);
    expect((await dao.findByDoctype('Item'))!.create, isTrue);
    await db.close();
  });

  test('upsertAll on empty list is a no-op', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final dao = DoctypePermissionDao(db.rawDatabase);
    await dao.upsertAll([]);

    final rows = await db.rawDatabase.query('doctype_permission');
    expect(rows, isEmpty);
    await db.close();
  });

  test('upsertAll replaces overlapping doctypes', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final dao = DoctypePermissionDao(db.rawDatabase);
    await dao.upsert(_perm(doctype: 'Customer', read: true, write: false));
    await dao.upsertAll([
      _perm(doctype: 'Customer', read: true, write: true),
      _perm(doctype: 'Supplier', read: true),
    ]);

    expect((await dao.findByDoctype('Customer'))!.write, isTrue);
    expect((await dao.findByDoctype('Supplier'))!.read, isTrue);
    final rows = await db.rawDatabase.query('doctype_permission');
    expect(rows, hasLength(2));
    await db.close();
  });

  test('deleteAll clears the table', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final dao = DoctypePermissionDao(db.rawDatabase);
    await dao.upsertAll([_perm(doctype: 'A'), _perm(doctype: 'B')]);
    await dao.deleteAll();

    final rows = await db.rawDatabase.query('doctype_permission');
    expect(rows, isEmpty);
    await db.close();
  });
}
