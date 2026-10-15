import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/cipher_database_factory.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;

/// Records what [CipherDatabaseFactory] forwards; never opens anything.
class _RecordingFactory implements cipher.DatabaseFactory {
  String? openedPath;
  cipher.OpenDatabaseOptions? options;
  final calls = <String>[];

  @override
  Future<cipher.Database> openDatabase(
    String path, {
    cipher.OpenDatabaseOptions? options,
  }) async {
    openedPath = path;
    this.options = options;
    throw StateError('not opened in tests');
  }

  @override
  Future<String> getDatabasesPath() async {
    calls.add('getDatabasesPath');
    return '/dbs';
  }

  @override
  Future<void> setDatabasesPath(String path) async =>
      calls.add('setDatabasesPath:$path');

  @override
  Future<void> deleteDatabase(String path) async =>
      calls.add('deleteDatabase:$path');

  @override
  Future<bool> databaseExists(String path) async {
    calls.add('databaseExists:$path');
    return true;
  }

  @override
  Future<Uint8List> readDatabaseBytes(String path) async {
    calls.add('readDatabaseBytes:$path');
    return Uint8List(0);
  }

  @override
  Future<void> writeDatabaseBytes(String path, Uint8List bytes) async =>
      calls.add('writeDatabaseBytes:$path');
}

void main() {
  test('adds the password and keeps every callback', () async {
    Future<void> onCreate(cipher.Database db, int v) async {}
    Future<void> onConfigure(cipher.Database db) async {}
    Future<void> onUpgrade(cipher.Database db, int a, int b) async {}
    Future<void> onDowngrade(cipher.Database db, int a, int b) async {}
    Future<void> onOpen(cipher.Database db) async {}
    final delegate = _RecordingFactory();
    final factory = CipherDatabaseFactory('k3y', delegate: delegate);

    await expectLater(
      factory.openDatabase(
        'x.db',
        options: cipher.OpenDatabaseOptions(
          version: 7,
          onCreate: onCreate,
          onConfigure: onConfigure,
          onUpgrade: onUpgrade,
          onDowngrade: onDowngrade,
          onOpen: onOpen,
          readOnly: true,
          singleInstance: false,
        ),
      ),
      throwsStateError,
    );

    expect(delegate.openedPath, 'x.db');
    final o = delegate.options!;
    expect(o, isA<cipher.SqlCipherOpenDatabaseOptions>());
    expect((o as cipher.SqlCipherOpenDatabaseOptions).password, 'k3y');
    expect(o.version, 7);
    expect(o.onCreate, same(onCreate));
    expect(o.onConfigure, same(onConfigure));
    expect(o.onUpgrade, same(onUpgrade));
    expect(o.onDowngrade, same(onDowngrade));
    expect(o.onOpen, same(onOpen));
    expect(o.readOnly, isTrue);
    expect(o.singleInstance, isFalse);
  });

  test('null options still get the password and default flags', () {
    final o =
        CipherDatabaseFactory.withPassword(null, 'p')
            as cipher.SqlCipherOpenDatabaseOptions;
    expect(o.password, 'p');
    expect(o.readOnly, isFalse);
    expect(o.singleInstance, isTrue);
    expect(o.version, isNull);
  });

  test('beforeOpen runs with the path before the delegate opens', () async {
    final delegate = _RecordingFactory();
    final seen = <String>[];
    final factory = CipherDatabaseFactory(
      'k',
      delegate: delegate,
      beforeOpen: (p) async {
        seen.add(p);
        expect(delegate.openedPath, isNull);
      },
    );
    await expectLater(factory.openDatabase('a.db'), throwsStateError);
    expect(seen, ['a.db']);
    expect(delegate.openedPath, 'a.db');
  });

  test('other calls are forwarded to the delegate', () async {
    final delegate = _RecordingFactory();
    final factory = CipherDatabaseFactory('k', delegate: delegate);
    expect(await factory.getDatabasesPath(), '/dbs');
    await factory.setDatabasesPath('/x');
    await factory.deleteDatabase('a');
    expect(await factory.databaseExists('a'), isTrue);
    await factory.readDatabaseBytes('a');
    await factory.writeDatabaseBytes('a', Uint8List(0));
    expect(delegate.calls, [
      'getDatabasesPath',
      'setDatabasesPath:/x',
      'deleteDatabase:a',
      'databaseExists:a',
      'readDatabaseBytes:a',
      'writeDatabaseBytes:a',
    ]);
  });
}
