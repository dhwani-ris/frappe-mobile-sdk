import 'dart:typed_data';

import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;

/// A [cipher.DatabaseFactory] that opens every database with SQLCipher and
/// [password].
///
/// [AppDatabase] opens its database with plain `OpenDatabaseOptions` carrying
/// its own schema callbacks. This factory keeps every one of those callbacks
/// and adds the password, so the same schema code runs against an encrypted
/// file. Every other call is passed straight to the delegate (by default
/// `sqflite_sqlcipher`'s `databaseFactory`).
///
/// [beforeOpen], when set, runs before each open with the database path. The
/// SDK uses it to clear a plain (unencrypted) file left by an earlier install,
/// which SQLCipher cannot open with a key.
class CipherDatabaseFactory implements cipher.DatabaseFactory {
  CipherDatabaseFactory(
    this.password, {
    cipher.DatabaseFactory? delegate,
    this.beforeOpen,
  }) : _delegate = delegate ?? cipher.databaseFactory;

  final String password;
  final Future<void> Function(String path)? beforeOpen;
  final cipher.DatabaseFactory _delegate;

  /// The delegate this factory forwards to.
  cipher.DatabaseFactory get delegate => _delegate;

  /// The options the delegate receives: the caller's, plus [password].
  static cipher.OpenDatabaseOptions withPassword(
    cipher.OpenDatabaseOptions? o,
    String password,
  ) => cipher.SqlCipherOpenDatabaseOptions(
    version: o?.version,
    onConfigure: o?.onConfigure,
    onCreate: o?.onCreate,
    onUpgrade: o?.onUpgrade,
    onDowngrade: o?.onDowngrade,
    onOpen: o?.onOpen,
    readOnly: o?.readOnly ?? false,
    singleInstance: o?.singleInstance ?? true,
    password: password,
  );

  @override
  Future<cipher.Database> openDatabase(
    String path, {
    cipher.OpenDatabaseOptions? options,
  }) async {
    await beforeOpen?.call(path);
    return _delegate.openDatabase(
      path,
      options: withPassword(options, password),
    );
  }

  @override
  Future<String> getDatabasesPath() => _delegate.getDatabasesPath();

  @override
  Future<void> setDatabasesPath(String path) =>
      _delegate.setDatabasesPath(path);

  @override
  Future<void> deleteDatabase(String path) => _delegate.deleteDatabase(path);

  @override
  Future<bool> databaseExists(String path) => _delegate.databaseExists(path);

  @override
  Future<Uint8List> readDatabaseBytes(String path) =>
      _delegate.readDatabaseBytes(path);

  @override
  Future<void> writeDatabaseBytes(String path, Uint8List bytes) =>
      _delegate.writeDatabaseBytes(path, bytes);
}
