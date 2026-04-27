import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/session_user.dart';
import 'package:frappe_mobile_sdk/src/services/session_user_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
  });
  tearDown(() async => db.close());

  test('set + current + stream emission', () async {
    final svc = SessionUserService(db);
    final emitted = <SessionUser?>[];
    final sub = svc.stream.listen(emitted.add);
    final u = SessionUser(
      name: 'x@y.com',
      roles: const ['A'],
      permissions: const {},
      userDefaults: const {},
      extras: const {},
    );
    await svc.set(u);
    await Future<void>.delayed(Duration.zero);
    expect(svc.current, u);
    expect(emitted, [u]);
    await sub.cancel();
    await svc.dispose();
  });

  test('persists to sdk_meta.session_user_json', () async {
    final svc = SessionUserService(db);
    final u = SessionUser(
      name: 'x',
      roles: const [],
      permissions: const {},
      userDefaults: const {},
      extras: const {},
    );
    await svc.set(u);
    final rows = await db.query('sdk_meta', limit: 1);
    expect(rows.first['session_user_json'], isNotNull);
    await svc.dispose();
  });

  test('restoreFromDb loads the persisted user', () async {
    final svc1 = SessionUserService(db);
    await svc1.set(SessionUser(
      name: 'a',
      roles: const [],
      permissions: const {},
      userDefaults: const {},
      extras: const {},
    ));
    await svc1.dispose();
    // new service reading same db
    final svc2 = SessionUserService(db);
    await svc2.restoreFromDb();
    expect(svc2.current?.name, 'a');
    await svc2.dispose();
  });

  test('clear emits null, wipes persisted json', () async {
    final svc = SessionUserService(db);
    await svc.set(SessionUser(
      name: 'a',
      roles: const [],
      permissions: const {},
      userDefaults: const {},
      extras: const {},
    ));
    await svc.clear();
    final rows = await db.query('sdk_meta', limit: 1);
    expect(rows.first['session_user_json'], isNull);
    expect(svc.current, isNull);
    await svc.dispose();
  });
}
