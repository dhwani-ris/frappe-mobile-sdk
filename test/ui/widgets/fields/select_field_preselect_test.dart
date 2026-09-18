import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/select_field.dart';

/// Mirrors the real host (`FrappeFormBuilder`): stores whatever the field
/// emits and rebuilds the field with it. Without the round-trip, a preselect
/// that re-fires on every build looks identical to one that fires once.
class _Host extends StatefulWidget {
  const _Host({
    super.key,
    required this.field,
    this.initial,
    this.enabled = true,
    this.allowPreselect = true,
  });

  final DocField field;
  final dynamic initial;
  final bool enabled;
  final bool allowPreselect;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late dynamic value = widget.initial;
  final List<dynamic> emissions = [];

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: FormBuilder(
          child: SelectField(
            field: widget.field,
            value: value,
            enabled: widget.enabled,
            allowPreselect: widget.allowPreselect,
            onChanged: (v) {
              emissions.add(v);
              setState(() => value = v);
            },
          ),
        ),
      ),
    );
  }
}

DocField _select({
  required String options,
  bool multi = false,
  bool readOnly = false,
  bool reqd = false,
}) => DocField(
  fieldname: 'status',
  fieldtype: 'Select',
  label: 'Status',
  options: options,
  allowMultiple: multi,
  readOnly: readOnly,
  reqd: reqd,
);

void main() {
  group('preselect is suppressed for a field the host excludes', () {
    testWidgets('single-select does not emit when allowPreselect is false', (
      tester,
    ) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(
        _Host(
          key: key,
          field: _select(options: 'Only'),
          allowPreselect: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(key.currentState!.emissions, isEmpty);
    });

    testWidgets('multi-select does not emit when allowPreselect is false', (
      tester,
    ) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(
        _Host(
          key: key,
          field: _select(options: 'Only', multi: true),
          allowPreselect: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(key.currentState!.emissions, isEmpty);
    });
  });

  group('preselect respects readOnly and enabled', () {
    testWidgets('a readOnly single-option select does not emit', (
      tester,
    ) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(
        _Host(
          key: key,
          field: _select(options: 'Only', readOnly: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(key.currentState!.emissions, isEmpty);
    });

    testWidgets('a disabled single-option select does not emit', (
      tester,
    ) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(
        _Host(
          key: key,
          field: _select(options: 'Only'),
          enabled: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(key.currentState!.emissions, isEmpty);
    });

    testWidgets('a readOnly single-option MULTI select does not emit', (
      tester,
    ) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(
        _Host(
          key: key,
          field: _select(options: 'Only', multi: true, readOnly: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(key.currentState!.emissions, isEmpty);
    });
  });

  group('preselect fires once, not on every rebuild', () {
    testWidgets('unchecking the sole option sticks', (tester) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(
        _Host(
          key: key,
          field: _select(options: 'Only', multi: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(key.currentState!.emissions, [
        'Only',
      ], reason: 'preselect must fire once on mount');

      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();

      expect(
        key.currentState!.emissions,
        ['Only', ''],
        reason: 'the uncheck must not be followed by a re-preselect',
      );
      expect(
        key.currentState!.value,
        '',
        reason: 'form data must agree with the unchecked box',
      );
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).first).value,
        isFalse,
      );
    });

    // The gate is `value == null`, so what it actually distinguishes is an
    // ABSENT key from a stored `''` — not "cleared" from "never touched".
    // Those have two callers, and the pulled document is the common one.
    testWidgets(
      'a stored empty string is never preselected — multi-select, whether it '
      'came from an explicit clear or from a pulled document',
      (tester) async {
        final key = GlobalKey<_HostState>();
        await tester.pumpWidget(
          _Host(
            key: key,
            initial: '',
            field: _select(options: 'Only', multi: true),
          ),
        );
        await tester.pumpAndSettle();
        expect(key.currentState!.emissions, isEmpty);
      },
    );

    testWidgets(
      'a stored empty string is never preselected — single-select, which is '
      'how every pulled document arrives',
      (tester) async {
        // Frappe stores an unset Select as `varchar NOT NULL DEFAULT ''` and
        // returns `""`. The pull writes it verbatim and
        // `_formData.addAll(widget.initialData ?? {})` normalises nothing, so
        // this — not the clear — is the case a field team meets first: a
        // synced record with a one-option Select stays empty, and with
        // `reqd: 1` the user must pick the sole choice by hand.
        final key = GlobalKey<_HostState>();
        await tester.pumpWidget(
          _Host(
            key: key,
            initial: '',
            field: _select(options: 'Only'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          key.currentState!.emissions,
          isEmpty,
          reason: 'a pulled document must not be auto-filled on open',
        );
      },
    );

    testWidgets(
      'an absent value IS preselected on mount — in practice, only a document '
      'this device created',
      (tester) async {
        final key = GlobalKey<_HostState>();
        await tester.pumpWidget(
          _Host(
            key: key,
            field: _select(options: 'Only'),
          ),
        );
        await tester.pumpAndSettle();
        expect(key.currentState!.emissions, ['Only']);
      },
    );
  });

  group('duplicate options', () {
    testWidgets('a duplicated sole option still preselects', (tester) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(
        _Host(
          key: key,
          field: _select(options: 'Only\nOnly'),
        ),
      );
      await tester.pumpAndSettle();
      expect(key.currentState!.emissions, ['Only']);
    });

    testWidgets('duplicate options do not crash the dropdown', (tester) async {
      await tester.pumpWidget(
        _Host(
          initial: 'A',
          field: _select(options: 'A\nA\nB'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final w = tester.widget<FormBuilderDropdown<String>>(
        find.byType(FormBuilderDropdown<String>),
      );
      expect(w.items, hasLength(2));
    });
  });
}
