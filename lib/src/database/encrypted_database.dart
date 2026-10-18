import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;

import '../utils/sdk_log.dart';
import 'app_database.dart' show DatabaseFactoryResolver;
import 'cipher_database_factory.dart';

/// First 16 bytes of every unencrypted SQLite file. An SQLCipher file starts
/// with random salt instead, so this header means "plain".
const List<int> _plainSqliteHeader = <int>[
  0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66, // "SQLite f"
  0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00, // "ormat 3\0"
];

/// Secure-storage key that holds the database password for [appName] (the
/// `databaseAppName` given to `FrappeSDK`).
@visibleForTesting
String databaseKeyName(String? appName) {
  final name = (appName == null || appName.trim().isEmpty)
      ? 'default'
      : appName.trim();
  return 'frappe_mobile_sdk.db_key.$name';
}

/// Returns the database password for [appName], making it on first use.
///
/// The password is 32 random bytes (base64url) from [Random.secure], kept
/// only in [storage] (Keychain on iOS, Keystore-backed on Android). Later
/// calls return the same value.
Future<String> databaseKey(
  FlutterSecureStorage storage, {
  String? appName,
}) async {
  final keyName = databaseKeyName(appName);
  final existing = await storage.read(key: keyName);
  if (existing != null && existing.isNotEmpty) return existing;
  final rnd = Random.secure();
  final key = base64UrlEncode(List<int>.generate(32, (_) => rnd.nextInt(256)));
  await storage.write(key: keyName, value: key);
  return key;
}

/// True when the file at [path] exists and starts with the plain SQLite
/// header (`"SQLite format 3\0"`), i.e. it is not encrypted.
Future<bool> isPlainSqliteFile(String path) async {
  final file = File(path);
  if (!await file.exists()) return false;
  final raf = await file.open();
  try {
    final head = await raf.read(_plainSqliteHeader.length);
    return listEquals(head, _plainSqliteHeader);
  } finally {
    await raf.close();
  }
}

/// Clears a plain database at [path] so it can be recreated encrypted.
///
/// Does nothing when there is no plain file. If the plain file still holds
/// unsynced work ([countUnsynced] > 0) it is kept and a [StateError] is
/// thrown: the app must sync (or sign out) before turning encryption on.
Future<void> clearPlainDatabaseIfSafe(
  String path, {
  required Future<int> Function(String path) countUnsynced,
  required Future<void> Function(String path) delete,
}) async {
  if (!await isPlainSqliteFile(path)) return;
  final unsynced = await countUnsynced(path);
  if (unsynced > 0) {
    throw StateError(
      'FrappeSDK(encryptDatabase: true): an unencrypted local database exists '
      'with $unsynced unsynced change(s). It cannot be converted in place. '
      'Sync (or sign out) with encryptDatabase: false first, then turn '
      'encryption on.',
    );
  }
  sdkLog(
    'FrappeSDK: replacing plain local database with an encrypted one '
    '(no unsynced changes).',
  );
  await delete(path);
}

/// Counts outbox rows not yet pushed plus pending attachment uploads in the
/// plain database at [path], opened through [factory] without a password.
Future<int> _countUnsyncedInPlainDb(
  cipher.DatabaseFactory factory,
  String path,
) async {
  final db = await factory.openDatabase(
    path,
    options: cipher.OpenDatabaseOptions(singleInstance: false),
  );
  try {
    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name IN ('outbox', 'pending_attachments')",
    )).map((r) => r['name']).toSet();
    var n = 0;
    if (tables.contains('outbox')) {
      final r = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM outbox WHERE state != 'done'",
      );
      n += (r.first['c'] as int?) ?? 0;
    }
    if (tables.contains('pending_attachments')) {
      final r = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM pending_attachments',
      );
      n += (r.first['c'] as int?) ?? 0;
    }
    return n;
  } finally {
    await db.close();
  }
}

Future<void> _deleteWithSiblings(
  cipher.DatabaseFactory factory,
  String path,
) async {
  await factory.deleteDatabase(path);
  for (final suffix in const ['', '-wal', '-shm', '-journal']) {
    final f = File('$path$suffix');
    if (await f.exists()) await f.delete();
  }
}

/// The [DatabaseFactoryResolver] `FrappeSDK(encryptDatabase: true)` uses:
/// SQLCipher with a per-install key from [storage].
DatabaseFactoryResolver encryptedDatabaseResolver({
  String? appName,
  FlutterSecureStorage storage = const FlutterSecureStorage(),
  cipher.DatabaseFactory? delegate,
}) {
  return (_) async {
    final password = await databaseKey(storage, appName: appName);
    final engine = delegate ?? cipher.databaseFactory;
    return CipherDatabaseFactory(
      password,
      delegate: engine,
      beforeOpen: (path) => clearPlainDatabaseIfSafe(
        path,
        countUnsynced: (p) => _countUnsyncedInPlainDb(engine, p),
        delete: (p) => _deleteWithSiblings(engine, p),
      ),
    );
  };
}
