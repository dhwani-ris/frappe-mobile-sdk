// Pins the guest-fallback contract of MetaService.resyncMobileConfiguration.
//
// The fallback exists for ONE deployed-server bug: the authenticated filter in
// `mobile_auth.configuration` can raise a PermissionError (a throwing
// `has_permission` on `DocType`) instead of returning a filtered list. Because
// the method is `allow_guest=True`, retrying unauthenticated still yields the
// workspace list.
//
// An UNSCOPED catch turned that narrow workaround into a correctness hazard,
// and these tests pin both halves of the fix:
//
//   1. SCOPE — only a 403 falls back. A 401 (dead credential) or a transport
//      failure (offline) must propagate. Answering a dead session with the
//      GUEST list hides the expiry behind a workspace that looks populated,
//      and every entry gets marked `isMobileForm: true`.
//   2. INTERSECTION — the guest list is unfiltered, so it is scoped against
//      the locally-synced permission matrix before it reaches the mobile-form
//      set. Subtract-only: a doctype with NO permission row is KEPT, because
//      `PermissionService` defaults a cache miss to ALLOW and a positive
//      filter would empty the workspace on a first launch.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/entities/doctype_permission_entity.dart';
import 'package:frappe_mobile_sdk/src/models/mobile_form_name.dart';
import 'package:frappe_mobile_sdk/src/services/meta_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

MobileFormName _form(String doctype) =>
    MobileFormName.fromJson({'mobile_workspace_item': doctype});

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('resyncMobileConfiguration guest fallback is scoped to 403', () {
    /// Runs a resync whose AUTHENTICATED call fails with [status], and reports
    /// whether the unauthenticated retry was issued.
    Future<({bool triedGuest, Object? thrown})> run(int status) async {
      final appDb = await AppDatabase.inMemoryDatabase();
      var triedGuest = false;
      final client = FrappeClient(
        'http://localhost',
        httpClient: MockClient((req) async {
          // The guest retry is the same URL without an Authorization header.
          if (!req.headers.containsKey('Authorization')) {
            triedGuest = true;
            return http.Response(jsonEncode({'data': []}), 200);
          }
          return http.Response(jsonEncode({'message': 'nope'}), status);
        }),
      );
      client.rest.setBearerToken('AT');
      final svc = MetaService(client, appDb);

      Object? thrown;
      try {
        await svc.resyncMobileConfiguration();
      } catch (e) {
        thrown = e;
      }
      await appDb.close();
      return (triedGuest: triedGuest, thrown: thrown);
    }

    test('a 403 DOES fall back — that is the whole reason it exists', () async {
      final r = await run(403);
      expect(r.triedGuest, isTrue);
      expect(r.thrown, isNull);
    });

    test('a 417 ALSO falls back', () async {
      // The commit that introduced this workaround recorded the symptom
      // ("can raise a PermissionError") but never the observed status. Frappe
      // maps PermissionError to 403, but a `has_permission` hook raising via a
      // bare `frappe.throw()` surfaces as ValidationException (417). Scoping
      // to 403 alone would make this method THROW on a deployment where it
      // previously recovered — killing the workaround silently.
      final r = await run(417);
      expect(r.triedGuest, isTrue);
      expect(r.thrown, isNull);
    });

    test('a 401 does NOT fall back, and propagates', () async {
      final r = await run(401);
      expect(
        r.triedGuest,
        isFalse,
        reason:
            'answering a dead credential with the unfiltered GUEST workspace '
            'list hides the expired session behind a populated-looking UI',
      );
      expect(r.thrown, isNotNull);
    });

    test('a 500 does NOT fall back, and propagates', () async {
      final r = await run(500);
      expect(r.triedGuest, isFalse);
      expect(r.thrown, isNotNull);
    });

    test('a transport failure does NOT fall back, and propagates', () async {
      final appDb = await AppDatabase.inMemoryDatabase();
      var calls = 0;
      final client = FrappeClient(
        'http://localhost',
        httpClient: MockClient((req) async {
          calls++;
          throw const SocketExceptionStub();
        }),
      );
      client.rest.setBearerToken('AT');
      final svc = MetaService(client, appDb);

      await expectLater(svc.resyncMobileConfiguration(), throwsA(anything));
      expect(
        calls,
        lessThanOrEqualTo(1),
        reason:
            'an offline client must not swap one failed request for a second '
            'failed request and report it as a permission story',
      );
      await appDb.close();
    });
  });

  group('the guest list is scoped against the local permission matrix', () {
    late AppDatabase appDb;
    late MetaService svc;

    setUp(() async {
      appDb = await AppDatabase.inMemoryDatabase();
      svc = MetaService(FrappeClient('http://localhost'), appDb);
    });

    tearDown(() async => appDb.close());

    Future<void> seedPermission(String doctype, {required bool read}) =>
        appDb.doctypePermissionDao.upsert(
          DoctypePermissionEntity(
            doctype: doctype,
            read: read,
            write: read,
            create: read,
            delete: read,
            submit: false,
            cancel: false,
            amend: false,
          ),
        );

    test('a doctype with NO permission row is KEPT', () async {
      // The trap: PermissionService defaults a cache miss to ALLOW, so a
      // positive `where(canRead)` filter is a no-op once permissions sync and,
      // on a first launch before they have synced, rests entirely on that
      // default. Emptying the workspace on first launch is a worse failure
      // than the churn this guards against.
      final kept = await svc.dropDeniedFormsForTest([
        _form('Customer'),
        _form('Supplier'),
      ]);
      expect(kept.map((f) => f.mobileDoctype), ['Customer', 'Supplier']);
    });

    test(
      'a doctype affirmatively denied (row exists, read=0) is DROPPED',
      () async {
        await seedPermission('Customer', read: true);
        await seedPermission('Secret Ledger', read: false);

        final kept = await svc.dropDeniedFormsForTest([
          _form('Customer'),
          _form('Secret Ledger'),
        ]);
        expect(kept.map((f) => f.mobileDoctype), ['Customer']);
      },
    );

    test(
      'a mix of denied and unknown keeps everything but the denied',
      () async {
        await seedPermission('Secret Ledger', read: false);

        final kept = await svc.dropDeniedFormsForTest([
          _form('Customer'), // no row -> kept
          _form('Secret Ledger'), // read=0 -> dropped
          _form('Supplier'), // no row -> kept
        ]);
        expect(kept.map((f) => f.mobileDoctype), ['Customer', 'Supplier']);
      },
    );

    test('an empty input yields an empty result', () async {
      expect(await svc.dropDeniedFormsForTest([]), isEmpty);
    });

    test(
      'a permission-table read failure keeps EVERY form (fails open)',
      () async {
        await seedPermission('Secret Ledger', read: false);
        // The lookup is now one bulk query instead of one per doctype, so its
        // failure mode is all-or-nothing. It must still fail OPEN: a workspace
        // that shrinks because a local read failed is worse than a form that
        // 403s per doctype. Closing the database is the cheapest real failure.
        await appDb.close();
        final kept = await svc.dropDeniedFormsForTest([
          _form('Customer'),
          _form('Secret Ledger'),
        ]);
        expect(kept.map((f) => f.mobileDoctype), ['Customer', 'Secret Ledger']);
        // Reopen so tearDown's close() has something valid to close.
        appDb = await AppDatabase.inMemoryDatabase();
      },
    );
  });

  test(
    'the AUTHENTICATED response is NOT intersected — it is already '
    'server-filtered, and a stale local matrix must not subtract from it',
    () async {
      final appDb = await AppDatabase.inMemoryDatabase();
      // Local matrix says denied, but the server returned it on the
      // authenticated call, so the server is the authority.
      await appDb.doctypePermissionDao.upsert(
        DoctypePermissionEntity(
          doctype: 'Customer',
          read: false,
          write: false,
          create: false,
          delete: false,
          submit: false,
          cancel: false,
          amend: false,
        ),
      );
      final client = FrappeClient(
        'http://localhost',
        httpClient: MockClient((req) async {
          if (req.url.path.contains('mobile_auth.configuration')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {'mobile_workspace_item': 'Customer'},
                ],
              }),
              200,
            );
          }
          // Meta fetch for Customer — irrelevant to the assertion.
          return http.Response(jsonEncode({'data': {}}), 200);
        }),
      );
      client.rest.setBearerToken('AT');
      final svc = MetaService(client, appDb);

      await svc.resyncMobileConfiguration();

      final names = await svc.getMobileFormDoctypeNames();
      expect(
        names,
        contains('Customer'),
        reason:
            'the authenticated list is server-scoped; intersecting it against '
            'a possibly-stale local matrix would subtract forms the user can '
            'legitimately read',
      );
      await appDb.close();
    },
  );
}

/// Stands in for a transport failure. `MockClient` surfaces whatever the
/// handler throws, and `RestHelper` maps it onto its transport path.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'SocketException: Network is unreachable';
}
