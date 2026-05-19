import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/services/permission_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('default permissive behavior (no row stored)', () {
    test(
      'canRead/canWrite/canCreate/canDelete/canSubmit all default true',
      () async {
        final db = await AppDatabase.inMemoryDatabase();
        final svc = PermissionService(FrappeClient('http://localhost'), db);

        expect(await svc.canRead('Customer'), isTrue);
        expect(await svc.canWrite('Customer'), isTrue);
        expect(await svc.canCreate('Customer'), isTrue);
        expect(await svc.canDelete('Customer'), isTrue);
        expect(await svc.canSubmit('Customer'), isTrue);
        await db.close();
      },
    );
  });

  group('saveFromLoginResponse — list shape', () {
    test('persists each entry as a row', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final svc = PermissionService(FrappeClient('http://localhost'), db);
      await svc.saveFromLoginResponse([
        {
          'doctype': 'Customer',
          'read': true,
          'write': true,
          'create': true,
          'delete': false,
          'submit': false,
        },
        {'doctype': 'Supplier', 'read': true, 'write': false},
      ]);

      expect(await svc.canRead('Customer'), isTrue);
      expect(await svc.canWrite('Customer'), isTrue);
      expect(await svc.canDelete('Customer'), isFalse);
      expect(await svc.canSubmit('Customer'), isFalse);

      expect(await svc.canRead('Supplier'), isTrue);
      expect(await svc.canWrite('Supplier'), isFalse);
      // Unset flag → fromApiMap reads false.
      expect(await svc.canCreate('Supplier'), isFalse);
      await db.close();
    });

    test('skips entries missing doctype', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final svc = PermissionService(FrappeClient('http://localhost'), db);
      await svc.saveFromLoginResponse([
        {'read': true}, // no doctype
        {'doctype': '', 'read': true}, // empty doctype
        {'doctype': 'Item', 'read': true, 'write': true},
      ]);
      expect(await svc.canRead('Item'), isTrue);
      expect(await svc.canWrite('Item'), isTrue);
      // The two skipped rows produce no permission record:
      expect(await svc.getDoctypePermission('Item'), isNotNull);
      await db.close();
    });
  });

  group('saveFromLoginResponse — map (legacy) shape', () {
    test('persists permissions nested under "permissions"', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final svc = PermissionService(FrappeClient('http://localhost'), db);
      await svc.saveFromLoginResponse({
        'roles': ['System Manager'],
        'permissions': {
          'Sales Invoice': {
            'read': true,
            'write': true,
            'create': true,
            'submit': true,
            'cancel': true,
            'amend': true,
          },
        },
      });
      expect(await svc.canRead('Sales Invoice'), isTrue);
      expect(await svc.canSubmit('Sales Invoice'), isTrue);
      await db.close();
    });

    test('null input is a no-op', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final svc = PermissionService(FrappeClient('http://localhost'), db);
      await svc.saveFromLoginResponse(null);
      // No row written; default permissive applies.
      expect(await svc.getDoctypePermission('X'), isNull);
      await db.close();
    });
  });

  group('syncFromApi', () {
    test('fetches and persists permissions from server response', () async {
      final mock = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'data': {
              'permissions': [
                {
                  'doctype': 'Lead',
                  'read': true,
                  'write': false,
                  'create': true,
                },
              ],
            },
          }),
          200,
        );
      });
      final db = await AppDatabase.inMemoryDatabase();
      final svc = PermissionService(
        FrappeClient('http://localhost', httpClient: mock),
        db,
      );
      final result = await svc.syncFromApi();
      expect(result, isA<Map<String, dynamic>>());
      expect(await svc.canRead('Lead'), isTrue);
      expect(await svc.canWrite('Lead'), isFalse);
      expect(await svc.canCreate('Lead'), isTrue);
      await db.close();
    });

    test('returns null when server response is not a map', () async {
      final mock = MockClient((req) async => http.Response('"oops"', 200));
      final db = await AppDatabase.inMemoryDatabase();
      final svc = PermissionService(
        FrappeClient('http://localhost', httpClient: mock),
        db,
      );
      expect(await svc.syncFromApi(), isNull);
      await db.close();
    });

    test('falls through to top-level when "data" key is missing', () async {
      final mock = MockClient(
        (req) async => http.Response(
          jsonEncode({
            'permissions': [
              {'doctype': 'Lead', 'read': true},
            ],
          }),
          200,
        ),
      );
      final db = await AppDatabase.inMemoryDatabase();
      final svc = PermissionService(
        FrappeClient('http://localhost', httpClient: mock),
        db,
      );
      final result = await svc.syncFromApi();
      expect(result, isNotNull);
      expect(await svc.canRead('Lead'), isTrue);
      await db.close();
    });
  });

  test('getDoctypePermission returns persisted row', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final svc = PermissionService(FrappeClient('http://localhost'), db);
    await svc.saveFromLoginResponse([
      {'doctype': 'Item', 'read': true, 'write': true, 'create': true},
    ]);
    final p = await svc.getDoctypePermission('Item');
    expect(p, isNotNull);
    expect(p!.read, isTrue);
    expect(p.write, isTrue);
    expect(p.create, isTrue);
    expect(p.delete, isFalse);
    await db.close();
  });

  test('upsert overwrites prior row', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final svc = PermissionService(FrappeClient('http://localhost'), db);
    await svc.saveFromLoginResponse([
      {'doctype': 'Item', 'read': true, 'write': false},
    ]);
    expect(await svc.canWrite('Item'), isFalse);

    await svc.saveFromLoginResponse([
      {'doctype': 'Item', 'read': true, 'write': true},
    ]);
    expect(await svc.canWrite('Item'), isTrue);
    await db.close();
  });
}
