import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('currentUser returns null when not authenticated', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final sdk = FrappeSDK.forTesting('http://test', db);

    expect(sdk.currentUser, isNull);
  });

  test('logout throws StateError when SDK not initialized', () async {
    final sdk = FrappeSDK(baseUrl: 'http://test');

    // logout() is async — use expectLater to catch the thrown StateError
    await expectLater(sdk.logout(), throwsA(isA<StateError>()));
  });

  test('security getter throws the canonical "not initialized" error pre-init '
      '(B4: guarded like every other service getter)', () {
    final sdk = FrappeSDK(baseUrl: 'http://test');
    // Must surface the shared, actionable message — not an opaque
    // "Null check operator used on a null value".
    expect(
      () => sdk.security,
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('SDK not initialized'),
        ),
      ),
    );
  });
}
