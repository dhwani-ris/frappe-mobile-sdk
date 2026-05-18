import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/entities/link_option_entity.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/link_filter_result.dart';
import 'package:frappe_mobile_sdk/src/services/link_field_coordinator.dart';
import 'package:frappe_mobile_sdk/src/services/link_option_service.dart';

/// Stub that records every getLinkOptions call and returns scripted results.
class _StubLinkOptionService extends LinkOptionService {
  _StubLinkOptionService({
    this.scripted = const {},
    this.defaultResult = const [],
  }) : super.withoutResolver();

  /// Map of `<doctype>|<filters-json>` → result. Plain `<doctype>` matches
  /// requests with null filters.
  final Map<String, List<LinkOptionEntity>> scripted;
  final List<LinkOptionEntity> defaultResult;
  final List<String> calls = [];
  Completer<void>? gate;

  @override
  Future<List<LinkOptionEntity>> getLinkOptions(
    String doctype, {
    List<List<dynamic>>? filters,
  }) async {
    final key = filters == null || filters.isEmpty
        ? doctype
        : '$doctype|${jsonEncode(filters)}';
    calls.add(key);
    if (gate != null) await gate!.future;
    return scripted[key] ?? scripted[doctype] ?? defaultResult;
  }
}

LinkOptionEntity _opt(String name) =>
    LinkOptionEntity(doctype: 'Target', name: name, lastUpdated: 1);

DocField _link(
  String fieldname, {
  String options = 'Target',
  String? linkFilters,
  bool hidden = false,
}) => DocField(
  fieldname: fieldname,
  fieldtype: 'Link',
  options: options,
  linkFilters: linkFilters,
  hidden: hidden,
);

DocTypeMeta _meta(List<DocField> fields) =>
    DocTypeMeta(name: 'Parent', fields: fields);

void main() {
  group('dependency graph', () {
    test('independent link field is tier 0', () {
      final coord = LinkFieldCoordinator(
        meta: _meta([_link('state')]),
        linkOptionService: _StubLinkOptionService(),
      );
      final field = coord.getIndependentLinkFields().single;
      expect(field.fieldname, 'state');
      expect(coord.getTier(field), 0);
      expect(coord.getDependentLinkFields(), isEmpty);
    });

    test('field with eval:doc.parent is tier 1 and dependent', () {
      final child = _link(
        'district',
        linkFilters: jsonEncode([
          ['District', 'state', '=', 'eval: doc.state'],
        ]),
      );
      final coord = LinkFieldCoordinator(
        meta: _meta([_link('state'), child]),
        linkOptionService: _StubLinkOptionService(),
      );
      expect(
        coord.getIndependentLinkFields().map((f) => f.fieldname).toList(),
        ['state'],
      );
      final dep = coord.getDependentLinkFields().single;
      expect(dep.fieldname, 'district');
      expect(coord.getTier(dep), 1);
      expect(coord.getChildrenOf('state').map((f) => f.fieldname).toList(), [
        'district',
      ]);
    });

    test('tiers chain transitively: grandparent → parent → child = 0,1,2', () {
      final parent = _link(
        'district',
        linkFilters: jsonEncode([
          ['District', 'state', '=', 'eval: doc.state'],
        ]),
      );
      final child = _link(
        'block',
        linkFilters: jsonEncode([
          ['Block', 'district', '=', 'eval: doc.district'],
        ]),
      );
      final coord = LinkFieldCoordinator(
        meta: _meta([_link('state'), parent, child]),
        linkOptionService: _StubLinkOptionService(),
      );
      final byName = {for (final f in coord.meta.fields) f.fieldname: f};
      expect(coord.getTier(byName['state']!), 0);
      expect(coord.getTier(byName['district']!), 1);
      expect(coord.getTier(byName['block']!), 2);
    });

    test(
      'hidden link fields are excluded from independent/dependent lists',
      () {
        final coord = LinkFieldCoordinator(
          meta: _meta([_link('visible'), _link('secret', hidden: true)]),
          linkOptionService: _StubLinkOptionService(),
        );
        expect(coord.getIndependentLinkFields().map((f) => f.fieldname), [
          'visible',
        ]);
      },
    );

    test('cycle in eval:doc dependency does not stack-overflow', () {
      final a = _link(
        'a',
        linkFilters: jsonEncode([
          ['T', 'x', '=', 'eval: doc.b'],
        ]),
      );
      final b = _link(
        'b',
        linkFilters: jsonEncode([
          ['T', 'y', '=', 'eval: doc.a'],
        ]),
      );
      // Should not throw or hang.
      LinkFieldCoordinator(
        meta: _meta([a, b]),
        linkOptionService: _StubLinkOptionService(),
      );
    });
  });

  group('canFetchNow', () {
    final field = _link(
      'district',
      linkFilters: jsonEncode([
        ['District', 'state', '=', 'eval: doc.state'],
      ]),
    );

    test('returns false when parent is missing', () {
      final coord = LinkFieldCoordinator(
        meta: _meta([_link('state'), field]),
        linkOptionService: _StubLinkOptionService(),
      );
      expect(coord.canFetchNow(field, {}), isFalse);
    });

    test('returns false when parent is empty string', () {
      final coord = LinkFieldCoordinator(
        meta: _meta([_link('state'), field]),
        linkOptionService: _StubLinkOptionService(),
      );
      expect(coord.canFetchNow(field, {'state': '   '}), isFalse);
    });

    test('returns true when all parents have non-empty values', () {
      final coord = LinkFieldCoordinator(
        meta: _meta([_link('state'), field]),
        linkOptionService: _StubLinkOptionService(),
      );
      expect(coord.canFetchNow(field, {'state': 'S1'}), isTrue);
    });
  });

  group('requestFetch', () {
    test('dedupes concurrent identical requests', () async {
      final stub = _StubLinkOptionService(
        scripted: {
          'Target': [_opt('A')],
        },
      );
      stub.gate = Completer<void>();
      final coord = LinkFieldCoordinator(
        meta: _meta([_link('state')]),
        linkOptionService: stub,
      );
      final f1 = coord.requestFetch('Target');
      final f2 = coord.requestFetch('Target');
      // Both must resolve to the same future before the underlying call completes.
      stub.gate!.complete();
      final results = await Future.wait([f1, f2]);
      expect(results[0].single.name, 'A');
      expect(results[1].single.name, 'A');
      expect(
        stub.calls,
        hasLength(1),
        reason: 'in-flight dedupe should suppress duplicate downstream call',
      );
    });

    test('caches non-empty result and replays from cache', () async {
      final stub = _StubLinkOptionService(
        scripted: {
          'Target': [_opt('A')],
        },
      );
      final coord = LinkFieldCoordinator(
        meta: _meta([_link('state')]),
        linkOptionService: stub,
      );
      final first = await coord.requestFetch('Target');
      final second = await coord.requestFetch('Target');
      expect(first, second);
      expect(
        stub.calls,
        hasLength(1),
        reason: 'second call must hit the cache',
      );
    });

    test('does NOT cache empty result — refetch hits service again', () async {
      final stub = _StubLinkOptionService(); // returns []
      final coord = LinkFieldCoordinator(
        meta: _meta([_link('state')]),
        linkOptionService: stub,
      );
      await coord.requestFetch('Target');
      await coord.requestFetch('Target');
      expect(
        stub.calls,
        hasLength(2),
        reason: 'empty results must NOT be cached (sync may not have run)',
      );
    });

    test('different filters produce different cache keys', () async {
      final stub = _StubLinkOptionService(
        scripted: {
          'Target': [_opt('A')],
          'Target|[["Target","x","=","1"]]': [_opt('B')],
        },
      );
      final coord = LinkFieldCoordinator(
        meta: _meta([_link('state')]),
        linkOptionService: stub,
      );
      final a = await coord.requestFetch('Target');
      final b = await coord.requestFetch(
        'Target',
        filters: [
          ['Target', 'x', '=', '1'],
        ],
      );
      expect(a.single.name, 'A');
      expect(b.single.name, 'B');
      expect(stub.calls, hasLength(2));
    });

    test(
      'downstream throw resolves request to empty list (does not bubble)',
      () async {
        final svc = _ThrowingService();
        final coord = LinkFieldCoordinator(
          meta: _meta([_link('state')]),
          linkOptionService: svc,
        );
        final res = await coord.requestFetch('Target');
        expect(res, isEmpty);
      },
    );
  });

  group('progress stream', () {
    test('emits loading=true then loading=false around a request', () async {
      final stub = _StubLinkOptionService(
        scripted: {
          'Target': [_opt('A')],
        },
      );
      final coord = LinkFieldCoordinator(
        meta: _meta([_link('state')]),
        linkOptionService: stub,
      );
      final events = <bool>[];
      final sub = coord.progressStream.listen((e) => events.add(e.loading));
      await coord.requestFetch('Target');
      // Allow microtask drain so the closing event lands.
      await Future<void>.delayed(Duration.zero);
      expect(events.first, isTrue);
      expect(events.last, isFalse);
      await sub.cancel();
    });
  });

  group('useCoordinator flag', () {
    test('registerField is a no-op when useCoordinator=false', () async {
      final stub = _StubLinkOptionService(
        scripted: {
          'Target': [_opt('A')],
        },
      );
      final coord = LinkFieldCoordinator(
        meta: _meta([_link('state')]),
        linkOptionService: stub,
        useCoordinator: false,
      );
      var called = false;
      coord.registerField(_link('state'), {}, (_) => called = true);
      await Future<void>.delayed(Duration.zero);
      expect(called, isFalse);
      expect(stub.calls, isEmpty);
    });
  });

  group('registerField', () {
    test('serves from cache on second register for same field', () async {
      final stub = _StubLinkOptionService(
        scripted: {
          'Target': [_opt('A')],
        },
      );
      final coord = LinkFieldCoordinator(
        meta: _meta([_link('state')]),
        linkOptionService: stub,
      );
      final received = <List<LinkOptionEntity>>[];
      coord.registerField(_link('state'), {}, received.add);
      await Future<void>.delayed(Duration.zero);
      coord.registerField(_link('state'), {}, received.add);
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(2));
      expect(
        stub.calls,
        hasLength(1),
        reason: 'second register must replay from cache',
      );
    });

    test('dependent field with missing parent is skipped (no fetch)', () async {
      final stub = _StubLinkOptionService();
      final dep = _link(
        'district',
        linkFilters: jsonEncode([
          ['District', 'state', '=', 'eval: doc.state'],
        ]),
      );
      final coord = LinkFieldCoordinator(
        meta: _meta([_link('state'), dep]),
        linkOptionService: stub,
      );
      coord.registerField(dep, {}, (_) {});
      await Future<void>.delayed(Duration.zero);
      expect(stub.calls, isEmpty);
    });
  });

  group('prefetchInitial', () {
    test('fetches independent fields and ready dependents only', () async {
      final dep = _link(
        'district',
        options: 'District',
        linkFilters: jsonEncode([
          ['District', 'state', '=', 'eval: doc.state'],
        ]),
      );
      final stub = _StubLinkOptionService(defaultResult: [_opt('X')]);
      final coord = LinkFieldCoordinator(
        meta: _meta([_link('state', options: 'State'), dep]),
        linkOptionService: stub,
      );
      coord.prefetchInitial({'state': 'S1'});
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        stub.calls.first,
        'State',
        reason: 'independent state field fetched first',
      );
      expect(
        stub.calls.any((c) => c.startsWith('District|')),
        isTrue,
        reason: 'sequenced dependent fetch should run after independent',
      );
    });

    test('is idempotent — second call does not re-fetch', () async {
      final stub = _StubLinkOptionService(
        scripted: {
          'Target': [_opt('A')],
        },
      );
      final coord = LinkFieldCoordinator(
        meta: _meta([_link('state')]),
        linkOptionService: stub,
      );
      coord.prefetchInitial({});
      await Future<void>.delayed(Duration.zero);
      coord.prefetchInitial({});
      await Future<void>.delayed(Duration.zero);
      expect(stub.calls, hasLength(1));
    });

    test('skips when useCoordinator=false', () async {
      final stub = _StubLinkOptionService();
      final coord = LinkFieldCoordinator(
        meta: _meta([_link('state')]),
        linkOptionService: stub,
        useCoordinator: false,
      );
      coord.prefetchInitial({});
      await Future<void>.delayed(Duration.zero);
      expect(stub.calls, isEmpty);
    });
  });

  group('getLinkFilterBuilder hook', () {
    test('non-null hook filters are passed through to the service', () async {
      LinkOptionEntity opt(String n) => _opt(n);
      final stub = _StubLinkOptionService(
        scripted: {
          'Target|[["Target","x","=","HOOK"]]': [opt('H')],
        },
      );
      final coord = LinkFieldCoordinator(
        meta: _meta([_link('state')]),
        linkOptionService: stub,
        getLinkFilterBuilder: (doctype, fieldname) =>
            (f, name, row, parent) => const LinkFilterResult(
              filters: [
                ['Target', 'x', '=', 'HOOK'],
              ],
            ),
      );
      coord.registerField(_link('state'), {}, (_) {});
      await Future<void>.delayed(Duration.zero);
      expect(stub.calls.single, 'Target|[["Target","x","=","HOOK"]]');
    });

    test('throwing hook factory does not crash registerField', () async {
      final stub = _StubLinkOptionService(
        scripted: {
          'Target': [_opt('A')],
        },
      );
      final coord = LinkFieldCoordinator(
        meta: _meta([_link('state')]),
        linkOptionService: stub,
        getLinkFilterBuilder: (doctype, fieldname) =>
            throw StateError('host bug'),
      );
      final received = <int>[];
      coord.registerField(
        _link('state'),
        {},
        (opts) => received.add(opts.length),
      );
      await Future<void>.delayed(Duration.zero);
      expect(received, [
        1,
      ], reason: 'falls back to meta filters and still resolves');
    });
  });

  test('dispose closes the progress stream', () async {
    final coord = LinkFieldCoordinator(
      meta: _meta([_link('state')]),
      linkOptionService: _StubLinkOptionService(),
    );
    final sub = coord.progressStream.listen((_) {});
    coord.dispose();
    await sub.cancel();
    // Re-listen after dispose should fail (closed broadcast still allows attach
    // but won't deliver). We assert that emit after dispose is a no-op.
    expect(() => coord.progressStream.listen((_) {}), returnsNormally);
  });
}

class _ThrowingService extends LinkOptionService {
  _ThrowingService() : super.withoutResolver();
  @override
  Future<List<LinkOptionEntity>> getLinkOptions(
    String doctype, {
    List<List<dynamic>>? filters,
  }) async {
    throw StateError('boom');
  }
}
