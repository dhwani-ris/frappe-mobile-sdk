import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'dispose closes session user service stream and resets _initialized',
    () async {
      final db = await AppDatabase.inMemoryDatabase();
      final sdk = FrappeSDK.forTesting('http://test', db);
      final stream = sdk.sessionUserService.stream;
      final events = <Object?>[];
      final sub = stream.listen(events.add, onDone: () => events.add('DONE'));

      await sdk.dispose();

      // Allow the controller close to flush.
      await Future<void>.delayed(Duration.zero);
      expect(
        events,
        contains('DONE'),
        reason: 'session user controller must be closed by dispose',
      );

      // After dispose, the getter must throw — its existing contract is to
      // raise when `!_initialized`. The actual exception type is the generic
      // `Exception` raised at frappe_sdk.dart:367-371.
      expect(() => sdk.sessionUserService, throwsA(isA<Exception>()));

      await sub.cancel();
    },
  );

  test('dispose is idempotent', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final sdk = FrappeSDK.forTesting('http://test', db);
    await sdk.dispose();
    await sdk.dispose(); // must not throw
  });
}
