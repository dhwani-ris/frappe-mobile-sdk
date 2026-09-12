import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/child_table_field.dart';

DocField _f(String n, String t) => DocField(fieldname: n, fieldtype: t);

/// Faithful to `mobile_control._MOBILE_CUSTOM_FIELDS`: hidden AND read-only.
/// Hidden-ness is the whole question for the round-trip tests below — a fixture
/// with visible fields would prove nothing about the real ones.
DocField _hidden(String n, String t) =>
    DocField(fieldname: n, fieldtype: t, hidden: true, readOnly: true);

/// Child doctype provisioned by mobile_control.
DocTypeMeta _provisioned() => DocTypeMeta(
  name: 'Order Item',
  isTable: true,
  fields: [
    _f('item_name', 'Data'),
    _hidden(mobileCreatedAtField, 'Datetime'),
    _hidden(mobileLatitudeLongitudeField, 'Geolocation'),
  ],
);

/// Child doctype on a server without mobile_control's custom fields.
DocTypeMeta _bare() => DocTypeMeta(
  name: 'Order Item',
  isTable: true,
  fields: [_f('item_name', 'Data')],
);

void main() {
  late List<dynamic> emitted;

  /// Stands in for the real child-row form: renders one button that submits a
  /// fixed row, which is all this test needs to reach the stamping path.
  Widget fakeFormBuilder(
    DocTypeMeta childMeta,
    Map<String, dynamic>? initialData,
    void Function(Map<String, dynamic>) onSubmit, {
    void Function(void Function() submit)? registerSubmit,
    bool readOnly = false,
  }) => ElevatedButton(
    onPressed: () => onSubmit({'item_name': 'item 1'}),
    child: const Text('SubmitRow'),
  );

  Widget host({
    required DocTypeMeta childMeta,
    MobileCreationCapture? capture,
  }) {
    emitted = [];
    return MaterialApp(
      home: Scaffold(
        body: ChildTableField(
          field: DocField(
            fieldname: 'items',
            fieldtype: 'Table',
            label: 'Items',
            options: 'Order Item',
          ),
          value: const [],
          onChanged: (v) => emitted = v,
          getMeta: (_) async => childMeta,
          formBuilder: fakeFormBuilder,
          creationCapture: capture,
        ),
      ),
    );
  }

  // Bounded pumps rather than pumpAndSettle: the modal sheet keeps scheduling
  // frames, so pumpAndSettle never returns here.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> addRow(WidgetTester tester) async {
    await tester.tap(find.text('Add Row'));
    await settle(tester);
    await tester.tap(find.text('SubmitRow'));
    await settle(tester);
  }

  testWidgets('Add Row stamps the new row with tap time and location', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        childMeta: _provisioned(),
        capture: MobileCreationCapture(
          checkReadiness: () async => LocationReadiness.ready,
          now: () => DateTime(2026, 8, 18, 9, 5, 3),
          readLocation: () async => 'GEO',
        ),
      ),
    );
    await addRow(tester);

    expect(emitted, hasLength(1));
    final row = emitted.first as Map<String, dynamic>;
    expect(row['item_name'], 'item 1');
    expect(row[mobileCreatedAtField], '2026-08-18 09:05:03');
    expect(row[mobileLatitudeLongitudeField], 'GEO');
  });

  testWidgets('the row timestamp is Add Row time, not row-submit time', (
    tester,
  ) async {
    var call = 0;
    await tester.pumpWidget(
      host(
        childMeta: _provisioned(),
        capture: MobileCreationCapture(
          checkReadiness: () async => LocationReadiness.ready,
          now: () => ++call == 1
              ? DateTime(2026, 8, 18, 9, 0, 0)
              : DateTime(2026, 8, 18, 23, 59, 59),
          readLocation: () async => null,
        ),
      ),
    );
    await addRow(tester);

    expect(
      (emitted.first as Map<String, dynamic>)[mobileCreatedAtField],
      '2026-08-18 09:00:00',
    );
  });

  testWidgets('a location that never lands still yields a usable row', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        childMeta: _provisioned(),
        capture: MobileCreationCapture(
          checkReadiness: () async => LocationReadiness.ready,
          now: () => DateTime(2026, 8, 18, 9, 5, 3),
          readLocation: () => Completer<String?>().future,
          saveWait: const Duration(milliseconds: 50),
        ),
      ),
    );
    await addRow(tester);

    final row = emitted.first as Map<String, dynamic>;
    expect(row['item_name'], 'item 1');
    expect(row[mobileCreatedAtField], '2026-08-18 09:05:03');
    expect(row.containsKey(mobileLatitudeLongitudeField), isFalse);
  });

  testWidgets('a child doctype without the fields is left untouched', (
    tester,
  ) async {
    // No capture must be started either — begin() would read GPS and prompt for
    // permission on a doctype with nowhere to put the result. A throwing reader
    // proves it is never called.
    await tester.pumpWidget(
      host(
        childMeta: _bare(),
        capture: MobileCreationCapture(
          checkReadiness: () async => LocationReadiness.ready,
          readLocation: () => throw StateError('must not read GPS'),
        ),
      ),
    );
    await addRow(tester);

    // `doctype` is stamped on every emitted row so a consumer need not
    // infer it from the parent field. What matters here is that NO
    // creation metadata was added.
    expect(emitted.first, {'item_name': 'item 1', 'doctype': 'Order Item'});
  });

  // The Add-Row tests above submit through a stub form, which cannot answer
  // whether a HIDDEN field survives a round trip through the real widget — a
  // stub proves only what the stub does. These two drive the actual
  // `FrappeFormBuilder` the SDK hands to child rows, so the answer comes from
  // the code under test. Data loss here would silently blank a row's creation
  // time the first time a user edited it.
  Widget realFormBuilder(
    DocTypeMeta childMeta,
    Map<String, dynamic>? initialData,
    void Function(Map<String, dynamic>) onSubmit, {
    void Function(void Function() submit)? registerSubmit,
    bool readOnly = false,
  }) => FrappeFormBuilder(
    meta: childMeta,
    initialData: initialData,
    onSubmit: onSubmit,
    registerSubmit: registerSubmit,
  );

  Widget hostWithRealForm({required List<dynamic> rows}) {
    emitted = [];
    return MaterialApp(
      home: Scaffold(
        body: ChildTableField(
          field: DocField(
            fieldname: 'items',
            fieldtype: 'Table',
            label: 'Items',
            options: 'Order Item',
          ),
          value: rows,
          onChanged: (v) => emitted = v,
          getMeta: (_) async => _provisioned(),
          formBuilder: realFormBuilder,
          creationCapture: MobileCreationCapture(
            checkReadiness: () async => LocationReadiness.ready,
            now: () => DateTime(2026, 8, 18, 9, 5, 3),
            readLocation: () async => 'GEO',
          ),
        ),
      ),
    );
  }

  testWidgets('editing a stamped row through the real form keeps its stamps', (
    tester,
  ) async {
    await tester.pumpWidget(
      hostWithRealForm(
        rows: [
          <String, dynamic>{
            'item_name': 'item 1',
            'mobile_uuid': 'child-uuid-1',
            mobileCreatedAtField: '2026-01-01 00:00:00',
            mobileLatitudeLongitudeField: 'ORIGINAL',
          },
        ],
      ),
    );
    await settle(tester);

    await tester.tap(find.byType(ListTile));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle(tester);

    expect(emitted, hasLength(1));
    final row = emitted.first as Map<String, dynamic>;
    expect(
      row[mobileCreatedAtField],
      '2026-01-01 00:00:00',
      reason: 'an edit must not blank the creation time',
    );
    expect(row[mobileLatitudeLongitudeField], 'ORIGINAL');
    expect(
      row['mobile_uuid'],
      'child-uuid-1',
      reason: 'preserveChildIdentity still does its own job',
    );
  });

  testWidgets('editing does not re-stamp a row with the capture time', (
    tester,
  ) async {
    // The row was created before this session; opening Edit Row must not start
    // a capture, and the row must keep its original values rather than picking
    // up 2026-08-18 / GEO from the capture wired into the host.
    await tester.pumpWidget(
      hostWithRealForm(
        rows: [
          <String, dynamic>{
            'item_name': 'item 1',
            mobileCreatedAtField: '2026-01-01 00:00:00',
          },
        ],
      ),
    );
    await settle(tester);

    await tester.tap(find.byType(ListTile));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle(tester);

    final row = emitted.first as Map<String, dynamic>;
    expect(row[mobileCreatedAtField], '2026-01-01 00:00:00');
    expect(
      row[mobileLatitudeLongitudeField],
      anyOf(isNull, ''),
      reason: 'an edit never captures a location',
    );
  });

  testWidgets('no capture supplied leaves the row unstamped', (tester) async {
    await tester.pumpWidget(host(childMeta: _provisioned()));
    await addRow(tester);

    // `doctype` is stamped on every emitted row so a consumer need not
    // infer it from the parent field. What matters here is that NO
    // creation metadata was added.
    expect(emitted.first, {'item_name': 'item 1', 'doctype': 'Order Item'});
  });
}
