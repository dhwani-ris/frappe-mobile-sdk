import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/document.dart';

void main() {
  group('Document.fromResolverRow', () {
    test(
      'offline-shape row uses mobile_uuid as localId, server_name as serverId',
      () {
        final doc = Document.fromResolverRow('Customer', {
          'mobile_uuid': 'uuid-1',
          'server_name': 'CUST-1',
          'name': 'CUST-1',
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
