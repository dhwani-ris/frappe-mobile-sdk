import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/cipher_database_factory.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(AppDatabaseTestSeam.resetSingleton);

  Future<DatabaseFactory> ffi(void Function(Object, StackTrace)? _) async =>
      databaseFactoryFfi;

  test('default: no resolver, not encrypted (FFI-then-sqflite path)', () {
    final sdk = FrappeSDK(baseUrl: 'http://test');
    expect(sdk.effectiveDatabaseFactoryResolver, isNull);
    expect(sdk.isDatabaseEncrypted, isFalse);
  });

  test('an explicit resolver is used as-is and wins over encryptDatabase', () {
    final sdk = FrappeSDK(
      baseUrl: 'http://test',
      databaseFactoryResolver: ffi,
      encryptDatabase: true,
    );
    expect(sdk.effectiveDatabaseFactoryResolver, same(ffi));
    expect(sdk.isDatabaseEncrypted, isFalse);
  });

  test('encryptDatabase resolves to a SQLCipher factory', () async {
    final sdk = FrappeSDK(
      baseUrl: 'http://test',
      databaseAppName: 'enc_app',
      encryptDatabase: true,
    );
    expect(sdk.isDatabaseEncrypted, isTrue);
    final factory = await sdk.effectiveDatabaseFactoryResolver!(null);
    expect(factory, isA<CipherDatabaseFactory>());
  });

  test('initialize() opens the database through the given resolver', () async {
    var calls = 0;
    final factory = _InMemoryRecordingFactory();
    final sdk = FrappeSDK(
      baseUrl: 'http://test',
      databaseAppName: 'resolver_test',
      databaseFactoryResolver: (onFailure) async {
        calls++;
        return factory;
      },
    );
    try {
      await sdk.initialize();
    } catch (_) {
      // Later init steps may need platform plugins absent in unit tests;
      // only the database open is under test here.
    }
    expect(calls, 1);
    expect(factory.openedPaths.single, endsWith('resolver_test_frappe.db'));
    await sdk.dispose();
    await (await AppDatabase.getInstance()).close();
  });
}

/// Records the path AppDatabase asks for and opens an in-memory FFI database
/// instead, so the test leaves no file behind.
class _InMemoryRecordingFactory implements DatabaseFactory {
  final openedPaths = <String>[];

  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) {
    openedPaths.add(path);
    return databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: options?.version,
        onConfigure: options?.onConfigure,
        onCreate: options?.onCreate,
        onUpgrade: options?.onUpgrade,
        singleInstance: false,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
