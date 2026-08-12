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

  test(
    'syncFromApi coerces int flags and full-replaces (prunes stale)',
    () async {
      final db = await AppDatabase.inMemoryDatabase();
      // Pre-seed a stale doctype not present in the refresh below.
      final seed = PermissionService(FrappeClient('http://localhost'), db);
      await seed.saveFromLoginResponse([
        {'doctype': 'Stale', 'read': true},
      ]);
      // Server returns Frappe-native INT flags (frappe.get_all on DocPerm).
      final mock = MockClient(
        (req) async => http.Response(
          jsonEncode({
            'data': {
              'permissions': [
                {
                  'doctype': 'Activity Logger',
                  'read': 1,
                  'write': 1,
                  'create': 1,
                },
              ],
            },
          }),
          200,
        ),
      );
      final svc = PermissionService(
        FrappeClient('http://localhost', httpClient: mock),
        db,
      );
      await svc.syncFromApi();
      // int flags coerced to bool:
      expect(await svc.canCreate('Activity Logger'), isTrue);
      // full-replace revoked the stale doctype → now DENIED (explicit all-false
      // row), NOT deleted (which would re-grant it via the allow-by-default
      // getter).
      expect(await svc.canRead('Stale'), isFalse);
      expect(await svc.canWrite('Stale'), isFalse);
      await db.close();
    },
  );

  test(
    'saveFromLoginResponse (login) upserts — never prunes the cache',
    () async {
      final db = await AppDatabase.inMemoryDatabase();
      final svc = PermissionService(FrappeClient('http://localhost'), db);
      await svc.saveFromLoginResponse([
        {'doctype': 'Customer', 'read': true},
        {'doctype': 'Supplier', 'read': true},
      ]);
      // A later login response with only a subset must NOT drop Supplier.
      await svc.saveFromLoginResponse([
        {'doctype': 'Customer', 'read': true, 'write': true},
      ]);
      expect(await svc.canWrite('Customer'), isTrue);
      expect(await svc.getDoctypePermission('Supplier'), isNotNull);
      await db.close();
    },
  );

  group('cache-miss reporting', () {
    test('a miss still allows, and is reported ONCE per doctype', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final missed = <String>[];
      final svc = PermissionService(
        FrappeClient('http://localhost'),
        db,
        onCacheMiss: missed.add,
      );

      // Behaviour is unchanged — the default is still allow, on every call.
      expect(await svc.canWrite('Never Synced'), isTrue);
      expect(await svc.canCreate('Never Synced'), isTrue);
      expect(await svc.canRead('Never Synced'), isTrue);

      // ...but the report is deduped. canRead/canWrite/canCreate/canDelete/
      // canSubmit each resolve independently and are called on list and form
      // BUILD paths, so the previous one-report-per-call behaviour emitted five
      // identical lines per gating build and drowned the signal it exists to
      // provide. Allow-vs-deny is unaffected; only reporting is suppressed.
      expect(missed, ['Never Synced']);
      await db.close();
    });

    test('a second doctype is still reported', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final missed = <String>[];
      final svc = PermissionService(
        FrappeClient('http://localhost'),
        db,
        onCacheMiss: missed.add,
      );

      expect(await svc.canWrite('Alpha'), isTrue);
      expect(await svc.canWrite('Beta'), isTrue);
      expect(await svc.canWrite('Alpha'), isTrue);

      expect(missed, ['Alpha', 'Beta']);
      await db.close();
    });

    test(
      'a cache write re-arms reporting for a still-missing doctype',
      () async {
        final db = await AppDatabase.inMemoryDatabase();
        final missed = <String>[];
        final svc = PermissionService(
          FrappeClient('http://localhost'),
          db,
          onCacheMiss: missed.add,
        );

        expect(await svc.canWrite('Never Synced'), isTrue);
        expect(missed, ['Never Synced']);

        // Rows arrived, but not for this doctype — so it is genuinely still
        // missing and worth surfacing again rather than staying silent for the
        // rest of the process.
        await svc.saveFromLoginResponse([
          {'doctype': 'Customer', 'read': true},
        ]);
        expect(await svc.canWrite('Never Synced'), isTrue);
        expect(missed, ['Never Synced', 'Never Synced']);
        await db.close();
      },
    );

    test('a synced row is NOT reported as a miss', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final missed = <String>[];
      final svc = PermissionService(
        FrappeClient('http://localhost'),
        db,
        onCacheMiss: missed.add,
      );
      await svc.saveFromLoginResponse([
        {'doctype': 'Customer', 'read': true, 'write': false},
      ]);

      expect(await svc.canWrite('Customer'), isFalse);
      expect(missed, isEmpty);
      await db.close();
    });
  });
}
