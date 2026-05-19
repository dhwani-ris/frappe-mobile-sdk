import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/document.dart';

void main() {
  group('Document.fromJson / toJson', () {
    test('round-trips a full document', () {
      final json = {
        'localId': 'uuid-abc',
        'doctype': 'Customer',
        'serverId': 'CUST-001',
        'data': {'customer_name': 'ACME'},
        'status': 'clean',
        'modified': 1700000000000,
      };
      final doc = Document.fromJson(json);
      expect(doc.localId, 'uuid-abc');
      expect(doc.doctype, 'Customer');
      expect(doc.serverId, 'CUST-001');
      expect(doc.status, 'clean');
      expect(doc.modified, 1700000000000);
      expect(doc.toJson(), json);
    });

    test('fromJson defaults status to "clean" when absent', () {
      final doc = Document.fromJson({
        'localId': 'u1',
        'doctype': 'X',
        'serverId': null,
        'data': <String, dynamic>{},
        'modified': 0,
      });
      expect(doc.status, 'clean');
    });
  });

  group('Document.create', () {
    test('creates a dirty document with the given localId and doctype', () {
      final before = DateTime.now().millisecondsSinceEpoch;
      final doc = Document.create(
        doctype: 'Lead',
        data: {'lead_name': 'Test'},
        localId: 'new-uuid',
      );
      final after = DateTime.now().millisecondsSinceEpoch;
      expect(doc.localId, 'new-uuid');
      expect(doc.doctype, 'Lead');
      expect(doc.status, 'dirty');
      expect(doc.serverId, isNull);
      expect(doc.modified, greaterThanOrEqualTo(before));
      expect(doc.modified, lessThanOrEqualTo(after));
    });
  });

  group('Document.fromServer', () {
    test('creates a clean document with serverId', () {
      final doc = Document.fromServer(
        doctype: 'Customer',
        serverId: 'CUST-99',
        data: {'customer_name': 'Test'},
        localId: 'uuid-server',
      );
      expect(doc.serverId, 'CUST-99');
      expect(doc.status, 'clean');
    });
  });

  group('Document state mutations', () {
    final base = Document(
      localId: 'u1',
      doctype: 'Customer',
      serverId: 'CUST-1',
      data: {'x': 1},
      status: 'clean',
      modified: 0,
    );

    test('markDirty returns new dirty document', () {
      final d = base.markDirty();
      expect(d.status, 'dirty');
      expect(d.localId, 'u1');
      expect(d.serverId, 'CUST-1');
    });

    test('markClean returns new clean document', () {
      final dirty = base.markDirty();
      final clean = dirty.markClean();
      expect(clean.status, 'clean');
    });

    test('markDeleted returns new deleted document', () {
      final d = base.markDeleted();
      expect(d.status, 'deleted');
    });

    test('updateData merges new fields and marks dirty', () {
      final updated = base.updateData({'y': 2});
      expect(updated.data['x'], 1);
      expect(updated.data['y'], 2);
      expect(updated.status, 'dirty');
    });

    test('updateData on deleted document stays deleted', () {
      final deleted = base.markDeleted();
      final updated = deleted.updateData({'z': 3});
      expect(updated.status, 'deleted');
    });

    test('copyWith overrides only specified fields', () {
      final copy = base.copyWith(status: 'dirty', serverId: 'CUST-2');
      expect(copy.status, 'dirty');
      expect(copy.serverId, 'CUST-2');
      expect(copy.localId, 'u1');
      expect(copy.doctype, 'Customer');
    });
  });

  group('Document.fromResolverRow', () {
    test(
      'offline-shape row uses mobile_uuid as localId, server_name as serverId',
      () {
        // Real SQLite SELECT * on docs__<doctype> has server_name, not name.
        final doc = Document.fromResolverRow('Customer', {
          'mobile_uuid': 'uuid-1',
          'server_name': 'CUST-1',
          'sync_status': 'synced',
          'customer_name': 'ACME',
          'modified': '2026-04-01 10:00:00',
        });
        expect(doc.localId, 'uuid-1');
        expect(doc.serverId, 'CUST-1');
        expect(doc.doctype, 'Customer');
        expect(doc.status, 'clean');
        expect(doc.data['customer_name'], 'ACME');
      },
    );

    test('online-shape row (no mobile_uuid, no server_name) falls back to name '
        'for both localId and serverId', () {
      final doc = Document.fromResolverRow('Customer', {
        'name': 'CUST-2',
        'customer_name': 'Beta',
      });
      expect(doc.localId, 'CUST-2');
      expect(doc.serverId, 'CUST-2');
      expect(doc.status, 'clean');
      expect(doc.data['customer_name'], 'Beta');
    });

    test('dirty offline row maps sync_status → status="dirty"', () {
      final doc = Document.fromResolverRow('Customer', {
        'mobile_uuid': 'uuid-2',
        'sync_status': 'dirty',
      });
      expect(doc.status, 'dirty');
    });

    test('sync_error and sync_blocked both map to status="sync_error"', () {
      final err = Document.fromResolverRow('Customer', {
        'mobile_uuid': 'uuid-3',
        'sync_status': 'sync_error',
      });
      final blocked = Document.fromResolverRow('Customer', {
        'mobile_uuid': 'uuid-4',
        'sync_status': 'sync_blocked',
      });
      expect(err.status, 'sync_error');
      expect(blocked.status, 'sync_error');
    });

    test('parses ISO modified string', () {
      final doc = Document.fromResolverRow('Customer', {
        'name': 'X',
        'modified': '2026-04-01 10:00:00',
      });
      // 2026-04-01T10:00:00 (interpreted as local time by DateTime.parse)
      final expected = DateTime(2026, 4, 1, 10).millisecondsSinceEpoch;
      expect(doc.modified, expected);
    });

    test('parses int modified (epoch ms)', () {
      final doc = Document.fromResolverRow('Customer', {
        'name': 'X',
        'modified': 1717250400000,
      });
      expect(doc.modified, 1717250400000);
    });

    test('missing modified falls back to "now" without throwing', () {
      final before = DateTime.now().millisecondsSinceEpoch;
      final doc = Document.fromResolverRow('Customer', {'name': 'X'});
      final after = DateTime.now().millisecondsSinceEpoch;
      expect(doc.modified, greaterThanOrEqualTo(before));
      expect(doc.modified, lessThanOrEqualTo(after));
    });

    test('row with neither name nor mobile_uuid yields empty localId', () {
      // Defensive: should not throw, but localId becomes empty string. The
      // caller typically filters these out (the link option service does
      // this in _rowsToEntities; document list tiles use it as a key).
      final doc = Document.fromResolverRow('Customer', {
        'customer_name': 'Anonymous',
      });
      expect(doc.localId, '');
      expect(doc.serverId, isNull);
    });
  });
}
