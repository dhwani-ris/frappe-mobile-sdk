import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/link_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/select_field.dart';

DocTypeMeta _meta(String name, List<DocField> fields) =>
    DocTypeMeta(name: name, fields: fields);

DocField _select(String fieldname) => DocField(
  fieldname: fieldname,
  fieldtype: 'Select',
  label: fieldname,
  options: 'Only',
);

DocField _link(String fieldname) => DocField(
  fieldname: fieldname,
  fieldtype: 'Link',
  label: fieldname,
  options: 'Item Group',
);

void main() {
  testWidgets(
    'FrappeFormBuilder passes meta.name down so the tree parent Link and '
    'naming_series are excluded from preselect',
    (tester) async {
      final changed = <String, dynamic>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: _meta('Item Group', [
                _select('naming_series'),
                _select('status'),
                _link('parent_item_group'),
              ]),
              onFieldChange: (name, value, data, {source = ChangeSource.user}) {
                changed[name] = value;
                return null;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      SelectField selectFor(String fieldname) => tester
          .widgetList<SelectField>(find.byType(SelectField))
          .firstWhere((w) => w.field.fieldname == fieldname);

      expect(selectFor('naming_series').allowPreselect, isFalse);
      expect(selectFor('status').allowPreselect, isTrue);

      final parentLink = tester
          .widgetList<LinkField>(find.byType(LinkField))
          .firstWhere((w) => w.field.fieldname == 'parent_item_group');
      expect(parentLink.allowPreselect, isFalse);

      // The ordinary Select still preselects; the reserved one stays untouched.
      expect(changed['status'], 'Only');
      expect(changed.containsKey('naming_series'), isFalse);
      expect(changed.containsKey('parent_item_group'), isFalse);
    },
  );

  testWidgets(
    'unchecking a preselected sole option survives the real form pipeline',
    (tester) async {
      // The stub host in select_field_preselect_test.dart feeds the emitted
      // value straight back. The real path also runs
      // `patchValue({tags: FieldNormalizer.normalize(field, '')})` -> `[]`
      // into FormBuilderCheckboxGroup, which is the half of the original bug
      // that made the widget and _formData disagree. This exercises it.
      Map<String, dynamic>? submitted;
      void Function()? submitFn;
      final changed = <String, dynamic>{};

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: _meta('Item Group', [
                DocField(
                  fieldname: 'tags',
                  fieldtype: 'Select',
                  label: 'Tags',
                  options: 'Only',
                  allowMultiple: true,
                ),
              ]),
              onSubmit: (data) => submitted = data,
              registerSubmit: (fn) => submitFn = fn,
              onFieldChange: (name, value, data, {source = ChangeSource.user}) {
                changed[name] = value;
                return null;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(changed['tags'], 'Only', reason: 'preselect fires once on mount');

      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();

      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).first).value,
        isFalse,
        reason: 'the box the user unchecked must stay unchecked',
      );
      expect(
        changed['tags'],
        '',
        reason: 'the last change the form saw must be the clear',
      );

      submitFn!.call();
      await tester.pumpAndSettle();
      expect(submitted, isNotNull);
      expect(
        submitted!['tags'],
        anyOf(isNull, '', isEmpty),
        reason: 'form data must not resurrect the preselected value on save',
      );
    },
  );

  testWidgets(
    'reactive mode goes through the same factory, so the gate still applies',
    (tester) async {
      // The reactive build path has its OWN createField call site
      // (form_builder.dart:2292) separate from the legacy one at 1455. Both
      // read the same _fieldFactory, but only `build` configures it — this
      // pins that the reactive path is not missed.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              mode: FormBuilderMode.reactive,
              meta: _meta('Item Group', [
                _select('naming_series'),
                _select('status'),
                _link('parent_item_group'),
              ]),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      SelectField selectFor(String fieldname) => tester
          .widgetList<SelectField>(find.byType(SelectField))
          .firstWhere((w) => w.field.fieldname == fieldname);

      expect(selectFor('naming_series').allowPreselect, isFalse);
      expect(selectFor('status').allowPreselect, isTrue);
      expect(
        tester
            .widgetList<LinkField>(find.byType(LinkField))
            .firstWhere((w) => w.field.fieldname == 'parent_item_group')
            .allowPreselect,
        isFalse,
      );
    },
  );
}
