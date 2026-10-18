import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/cipher_database_factory.dart';
import 'package:frappe_mobile_sdk/src/database/encrypted_database.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('enc_db_test');
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// A plain SQLite file with the SDK's system tables and [pending] outbox
  /// rows in state `pending` (plus one `done` row that must not count).
  Future<String> plainDb({int pending = 0}) async {
    final path = '${tmp.path}/app_frappe.db';
    final db = await databaseFactoryFfi.openDatabase(path);
    for (final stmt in systemTablesDDL()) {
      await db.execute(stmt);
    }
    Future<void> add(String state) => db.insert('outbox', {
      'doctype': 'Note',
      'mobile_uuid': 'u-$state-${DateTime.now().microsecondsSinceEpoch}',
      'operation': 'INSERT',
      'state': state,
      'created_at': 1,
    });
    await add('done');
    for (var i = 0; i < pending; i++) {
      await add('pending');
    }
    await db.close();
    return path;
  }

  group('databaseKey', () {
    test('is made once and reused', () async {
      const storage = FlutterSecureStorage();
      final first = await databaseKey(storage, appName: 'app');
      final second = await databaseKey(storage, appName: 'app');
      expect(first, second);
      expect(first.length, greaterThanOrEqualTo(43)); // 32 bytes, base64url
      expect(await storage.read(key: databaseKeyName('app')), first);
    });

    test('is namespaced by app name', () async {
      const storage = FlutterSecureStorage();
      final a = await databaseKey(storage, appName: 'a');
      final b = await databaseKey(storage, appName: 'b');
      expect(a, isNot(b));
      expect(databaseKeyName(null), databaseKeyName(''));
    });

    test('an existing key is returned unchanged', () async {
      FlutterSecureStorage.setMockInitialValues({
        databaseKeyName('app'): 'kept',
      });
      expect(
        await databaseKey(const FlutterSecureStorage(), appName: 'app'),
        'kept',
      );
    });
  });

  group('isPlainSqliteFile', () {
    test('true for a plain SQLite file', () async {
      expect(await isPlainSqliteFile(await plainDb()), isTrue);
    });

    test('false for a missing file', () async {
      expect(await isPlainSqliteFile('${tmp.path}/none.db'), isFalse);
    });

    test(
      'false for random (encrypted-looking) bytes and short files',
      () async {
        final enc = File('${tmp.path}/enc.db')
          ..writeAsBytesSync(List<int>.generate(64, (i) => (i * 37) & 0xff));
        final short = File('${tmp.path}/short.db')..writeAsStringSync('SQLite');
        expect(await isPlainSqliteFile(enc.path), isFalse);
        expect(await isPlainSqliteFile(short.path), isFalse);
      },
    );
  });

  group('clearPlainDatabaseIfSafe', () {
    test('deletes a plain file with nothing unsynced', () async {
      final path = await plainDb();
      final deleted = <String>[];
      await clearPlainDatabaseIfSafe(
        path,
        countUnsynced: (_) async => 0,
        delete: (p) async => deleted.add(p),
      );
      expect(deleted, [path]);
    });

    test(
      'throws StateError and keeps the file when work is unsynced',
      () async {
        final path = await plainDb();
        final deleted = <String>[];
        await expectLater(
          clearPlainDatabaseIfSafe(
            path,
            countUnsynced: (_) async => 3,
            delete: (p) async => deleted.add(p),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('3 unsynced'),
            ),
          ),
        );
        expect(deleted, isEmpty);
      },
    );

    test('leaves a non-plain or missing file alone', () async {
      var counted = false;
      await clearPlainDatabaseIfSafe(
        '${tmp.path}/none.db',
        countUnsynced: (_) async {
          counted = true;
          return 0;
        },
        delete: (_) async => fail('must not delete'),
      );
      expect(counted, isFalse);
    });
  });

  // End to end through the resolver. The FFI engine ignores the password, so
  // this exercises the plain-file guard (count + delete) with real SQLite,
  // not the encryption itself (that needs the SQLCipher native library).
  group('encryptedDatabaseResolver', () {
    test('returns a CipherDatabaseFactory keyed from secure storage', () async {
      final factory = await encryptedDatabaseResolver(
        appName: 'app',
        delegate: databaseFactoryFfi,
      )(null);
      expect(factory, isA<CipherDatabaseFactory>());
      expect(
        (factory as CipherDatabaseFactory).password,
        await const FlutterSecureStorage().read(key: databaseKeyName('app')),
      );
    });

    test('replaces a plain DB that has only done outbox rows', () async {
      final path = await plainDb();
      final factory = await encryptedDatabaseResolver(
        delegate: databaseFactoryFfi,
      )(null);
      final db = await factory.openDatabase(path);
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE name = 'outbox'",
      );
      await db.close();
      expect(tables, isEmpty, reason: 'old file was deleted and recreated');
    });

    test('refuses a plain DB with pending outbox rows', () async {
      final path = await plainDb(pending: 2);
      final factory = await encryptedDatabaseResolver(
        delegate: databaseFactoryFfi,
      )(null);
      await expectLater(factory.openDatabase(path), throwsStateError);
      expect(await File(path).exists(), isTrue);
      expect(await isPlainSqliteFile(path), isTrue);
    });
  });
}
