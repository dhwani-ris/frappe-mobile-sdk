import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

class _FakeLinkOptionService extends LinkOptionService {
  final Completer<List<LinkOptionEntity>> _completer = Completer();
  _FakeLinkOptionService() : super.withoutResolver();

  @override
  Future<List<LinkOptionEntity>> getLinkOptions(
    String doctype, {
    List<List<dynamic>>? filters,
  }) => _completer.future;

  void resolve(List<LinkOptionEntity> options) {
    if (!_completer.isCompleted) _completer.complete(options);
  }
}

LinkOptionEntity _opt(String name) => LinkOptionEntity(
  doctype: 'TestDocType',
  name: name,
  label: name,
  lastUpdated: 0,
);

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: FormBuilder(child: child)),
);

DocField _field({bool readOnly = false, String options = 'TestDocType'}) =>
    DocField(
      fieldname: 'test_link',
      fieldtype: 'Link',
      label: 'Test Link',
      options: options,
      readOnly: readOnly,
    );

void main() {
  group('static options branch', () {
    testWidgets('does not preselect when allowPreselect is false', (
      tester,
    ) async {
      final emissions = <dynamic>[];
      await tester.pumpWidget(
        _wrap(
          LinkField(
            field: _field(),
            options: const ['Only'],
            allowPreselect: false,
            onChanged: emissions.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(emissions, isEmpty);
    });

    testWidgets('does not preselect a readOnly field', (tester) async {
      final emissions = <dynamic>[];
      await tester.pumpWidget(
        _wrap(
          LinkField(
            field: _field(readOnly: true),
            options: const ['Only'],
            onChanged: emissions.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(emissions, isEmpty);
    });

    testWidgets('does not preselect a disabled field', (tester) async {
      final emissions = <dynamic>[];
      await tester.pumpWidget(
        _wrap(
          LinkField(
            field: _field(),
            options: const ['Only'],
            enabled: false,
            onChanged: emissions.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(emissions, isEmpty);
    });

    testWidgets('still preselects an ordinary editable field', (tester) async {
      final emissions = <dynamic>[];
      await tester.pumpWidget(
        _wrap(
          LinkField(
            field: _field(),
            options: const ['Only'],
            onChanged: emissions.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(emissions, ['Only']);
    });
  });

  group('service-loaded options branch', () {
    testWidgets('does not preselect when allowPreselect is false', (
      tester,
    ) async {
      final svc = _FakeLinkOptionService();
      final emissions = <dynamic>[];
      await tester.pumpWidget(
        _wrap(
          LinkField(
            field: _field(),
            linkOptionService: svc,
            allowPreselect: false,
            onChanged: emissions.add,
          ),
        ),
      );
      svc.resolve([_opt('Only')]);
      await tester.pumpAndSettle();
      expect(emissions, isEmpty);
    });

    testWidgets('does not preselect a readOnly field', (tester) async {
      final svc = _FakeLinkOptionService();
      final emissions = <dynamic>[];
      await tester.pumpWidget(
        _wrap(
          LinkField(
            field: _field(readOnly: true),
            linkOptionService: svc,
            onChanged: emissions.add,
          ),
        ),
      );
      svc.resolve([_opt('Only')]);
      await tester.pumpAndSettle();
      expect(emissions, isEmpty);
    });

    testWidgets('still preselects an ordinary editable field', (tester) async {
      final svc = _FakeLinkOptionService();
      final emissions = <dynamic>[];
      await tester.pumpWidget(
        _wrap(
          LinkField(
            field: _field(),
            linkOptionService: svc,
            onChanged: emissions.add,
          ),
        ),
      );
      svc.resolve([_opt('Only')]);
      await tester.pumpAndSettle();
      expect(emissions, ['Only']);
    });
  });

  _duplicateOptionTests();
  _emptyStoredValueTests();
}

// ---------------------------------------------------------------------------
// An empty stored value. `SelectField._canPreselect` gates on `value == null`,
// so a stored `''` suppresses its preselect. `LinkField` deliberately does
// NOT share that gate: both of its preselect sites still test "no valid
// selection" (`validInitialValue == null || validInitialValue.isEmpty` for
// static options, `!hasValidSelection` for service-loaded ones), so `''` is
// treated as "nothing usable is selected" and the sole option IS applied.
//
// That matters because `''` is exactly what a PULLED document carries: Frappe
// stores an unset Link as `varchar NOT NULL DEFAULT ''` and returns `""`, the
// pull writes it verbatim, and `_formData.addAll(widget.initialData ?? {})`
// normalises nothing in between. So a single-option Link on a synced record IS
// auto-filled where the equivalent Select is not.
//
// These tests pin that divergence rather than endorse it. The clear/re-fire
// loop that forced Select's stricter gate is specific to the multi-select
// checkbox path, which `LinkField` has no equivalent of, so aligning the two
// is a behaviour change that needs its own evidence — not a ride-along on
// this one. Pinning it here means the next person to change either widget
// sees the asymmetry instead of discovering it in the field.
// ---------------------------------------------------------------------------
void _emptyStoredValueTests() {
  group('an empty stored value', () {
    testWidgets('static options: `\'\'` still preselects', (tester) async {
      final emissions = <dynamic>[];
      await tester.pumpWidget(
        _wrap(
          LinkField(
            field: _field(),
            value: '',
            options: const ['Only'],
            onChanged: emissions.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        emissions,
        ['Only'],
        reason:
            'LinkField gates on "no valid selection", not on `value == null` '
            'the way SelectField does',
      );
    });

    testWidgets('service-loaded options: `\'\'` still preselects', (
      tester,
    ) async {
      final svc = _FakeLinkOptionService();
      final emissions = <dynamic>[];
      await tester.pumpWidget(
        _wrap(
          LinkField(
            field: _field(),
            value: '',
            linkOptionService: svc,
            onChanged: emissions.add,
          ),
        ),
      );
      svc.resolve([_opt('Only')]);
      await tester.pumpAndSettle();
      expect(emissions, ['Only']);
    });

    testWidgets('the reserved-field guard still wins over it', (tester) async {
      // The asymmetry above must not become a hole in what this PR is for:
      // `parent_<doctype>` on a one-node tree stays untouched even though its
      // stored value is the same `''`.
      final emissions = <dynamic>[];
      await tester.pumpWidget(
        _wrap(
          LinkField(
            field: _field(),
            value: '',
            options: const ['Only'],
            allowPreselect: false,
            onChanged: emissions.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(emissions, isEmpty);
    });
  });
}

// ---------------------------------------------------------------------------
// Duplicate host-supplied static options. `linkOptions` is a `createField`
// parameter the SDK never populates itself, so the list is whatever the host
// passes — and it reaches the same FormBuilderDropdown that asserts
// "There should be exactly one item with [DropdownButton]'s value".
// ---------------------------------------------------------------------------
void _duplicateOptionTests() {
  group('duplicate static options', () {
    testWidgets('do not crash the dropdown', (tester) async {
      await tester.pumpWidget(
        _wrap(
          LinkField(
            field: _field(),
            value: 'A',
            options: const ['A', 'A', 'B'],
            onChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final w = tester.widget<FormBuilderDropdown<String>>(
        find.byType(FormBuilderDropdown<String>),
      );
      expect(w.items, hasLength(2));
    });

    testWidgets('a duplicated sole option still preselects', (tester) async {
      final emissions = <dynamic>[];
      await tester.pumpWidget(
        _wrap(
          LinkField(
            field: _field(),
            options: const ['Only', 'Only'],
            onChanged: emissions.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(emissions, ['Only']);
    });
  });
}
