import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/idempotency_strategy.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';

DocTypeMeta meta({
  String name = 'X',
  String? autoname,
  List<DocField> fields = const [],
}) =>
    DocTypeMeta(name: name, autoname: autoname, fields: fields);

void main() {
  test('L1 when autoname=field:mobile_uuid', () {
    final s = IdempotencyStrategy(serverHasDedupHook: false);
    final pick = s.pick(meta(autoname: 'field:mobile_uuid'));
    expect(pick.level, IdempotencyLevel.userSetNaming);
  });

  test('L2 when autoname absent but server has hook', () {
    final s = IdempotencyStrategy(serverHasDedupHook: true);
    final pick = s.pick(meta(autoname: null));
    expect(pick.level, IdempotencyLevel.serverDedupHook);
  });

  test('L3 when neither — warning emitted if no mobile_uuid field', () {
    final warnings = <String>[];
    final s = IdempotencyStrategy(
      serverHasDedupHook: false,
      onInitWarning: warnings.add,
    );
    final pick = s.pick(meta(name: 'NoMobileUuid', autoname: null));
    expect(pick.level, IdempotencyLevel.preRetryGetCheck);
    expect(warnings.length, 1);
    expect(warnings.single, contains('NoMobileUuid'));
  });

  test('L3 without warning when mobile_uuid field is present', () {
    final warnings = <String>[];
    final s = IdempotencyStrategy(
      serverHasDedupHook: false,
      onInitWarning: warnings.add,
    );
    final m = meta(
      autoname: null,
      fields: [
        DocField(fieldname: 'mobile_uuid', fieldtype: 'Data', label: 'M'),
      ],
    );
    final pick = s.pick(m);
    expect(pick.level, IdempotencyLevel.preRetryGetCheck);
    expect(warnings, isEmpty);
  });

  test('override wins', () {
    final s = IdempotencyStrategy(
      serverHasDedupHook: true,
      override: IdempotencyLevel.preRetryGetCheck,
    );
    final pick = s.pick(meta(autoname: 'field:mobile_uuid'));
    expect(pick.level, IdempotencyLevel.preRetryGetCheck);
  });

  test('caches decision per doctype — warning fires once', () {
    var warnings = 0;
    final s = IdempotencyStrategy(
      serverHasDedupHook: false,
      onInitWarning: (_) => warnings++,
    );
    final m = meta(name: 'CachedDoctype', autoname: null);
    s.pick(m);
    s.pick(m);
    expect(warnings, 1, reason: 'warning emitted once per doctype per session');
  });

  test('hasMobileUuidField is true when field is present', () {
    final s = IdempotencyStrategy(serverHasDedupHook: false);
    final m = meta(
      fields: [
        DocField(fieldname: 'mobile_uuid', fieldtype: 'Data', label: 'M'),
      ],
    );
    final pick = s.pick(m);
    expect(pick.hasMobileUuidField, isTrue);
  });
}
