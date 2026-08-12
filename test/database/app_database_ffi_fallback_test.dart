import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    AppDatabaseTestSeam.resetSingleton();
  });

  test('getInstance uses injected factoryResolver', () async {
    bool resolverCalled = false;
    final db = await AppDatabase.getInstance(
      factoryResolver: (onFailure) async {
        resolverCalled = true;
        return databaseFactoryFfi;
      },
    );
    expect(resolverCalled, isTrue);
    expect(db, isNotNull);
    await db.close();
  });

  test('getInstance falls back when factoryResolver throws', () async {
    Object? capturedError;
    StackTrace? capturedStack;

    final db = await AppDatabase.getInstance(
      onFfiInitFailure: (e, st) {
        capturedError = e;
        capturedStack = st;
      },
      factoryResolver: (onFailure) async {
        try {
          throw Exception('simulated FFI failure');
        } catch (e, st) {
          onFailure?.call(e, st);
          return databaseFactory;
        }
      },
    );

    expect(capturedError, isA<Exception>());
    expect(capturedStack, isNotNull);
    expect(db, isNotNull);

    final raw = db.rawDatabase;
    await raw.execute('DROP TABLE IF EXISTS _fb_test');
    await raw.execute('CREATE TABLE _fb_test (id INTEGER PRIMARY KEY)');
    await raw.insert('_fb_test', {'id': 42});
    final rows = await raw.query('_fb_test');
    expect(rows.length, 1);
    expect(rows.first['id'], equals(42));

    await db.close();
  });

  test(
    'concurrent getInstance calls return same instance (no double-open)',
    () async {
      int createCount = 0;
      Future<DatabaseFactory> countingResolver(
        void Function(Object, StackTrace)? _,
      ) async {
        createCount++;
        return databaseFactoryFfi;
      }

      final results = await Future.wait([
        AppDatabase.getInstance(factoryResolver: countingResolver),
        AppDatabase.getInstance(factoryResolver: countingResolver),
        AppDatabase.getInstance(factoryResolver: countingResolver),
      ]);

      expect(identical(results[0], results[1]), isTrue);
      expect(identical(results[1], results[2]), isTrue);
      expect(createCount, equals(1));

      await results[0].close();
    },
  );
}
