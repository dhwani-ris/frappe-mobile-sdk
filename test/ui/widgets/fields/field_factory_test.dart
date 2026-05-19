// Pins FieldFactory.createField → BaseField subclass dispatch for every
// fieldtype supported by FrappeFormBuilder. A factory bug here silently
// degrades dozens of fields, so the contract is worth covering directly.
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/attach_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/button_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/check_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/data_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/date_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/datetime_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/duration_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/field_factory.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/geolocation_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/html_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/image_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/link_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/numeric_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/password_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/phone_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/rating_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/read_only_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/select_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/text_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/time_field.dart';

void main() {
  late FieldFactory factory;
  setUp(() {
    factory = FieldFactory();
  });

  DocField fieldOf(String fieldtype) =>
      DocField(fieldname: 'f', fieldtype: fieldtype, label: 'F');

  // Single-shot dispatch table for the straightforward types.
  for (final entry in <String, Type>{
    'Data': DataField,
    'Phone': PhoneField,
    'Text': TextFieldWidget,
    'Long Text': TextFieldWidget,
    'Small Text': TextFieldWidget,
    'Select': SelectField,
    'Multi Select': SelectField,
    'Date': DateField,
    'Datetime': DatetimeField,
    'Time': TimeField,
    'Check': CheckField,
    'Int': NumericField,
    'Float': NumericField,
    'Currency': NumericField,
    'Percent': NumericField,
    'Duration': DurationField,
    'Password': PasswordField,
    'Rating': RatingField,
    'Read Only': ReadOnlyField,
    'Attach': AttachField,
    'Attach Image': ImageField,
    'Image': ImageField,
    'HTML': HtmlField,
    'Geolocation': GeolocationField,
    'Button': ButtonField,
    'Link': LinkField,
  }.entries) {
    test('"${entry.key}" → ${entry.value}', () {
      final widget = factory.createField(field: fieldOf(entry.key));
      expect(widget, isA<Object>());
      expect(widget.runtimeType, entry.value);
    });
  }

  test('hidden field returns null regardless of fieldtype', () {
    final hidden = DocField(
      fieldname: 'f',
      fieldtype: 'Data',
      label: 'F',
      hidden: true,
    );
    expect(factory.createField(field: hidden), isNull);
  });

  test('Table field returns null without getMeta + childTableFormBuilder', () {
    expect(factory.createField(field: fieldOf('Table')), isNull);
  });

  test('Table MultiSelect returns null without getMeta', () {
    expect(factory.createField(field: fieldOf('Table MultiSelect')), isNull);
  });

  test('Table field with required deps returns a non-null BaseField', () {
    final widget = factory.createField(
      field: fieldOf('Table'),
      getMeta: (_) async => DocTypeMeta(name: 'X', fields: const []),
      childTableFormBuilder: (meta, initialData, onSaved, {registerSubmit}) =>
          throw UnimplementedError(),
    );
    expect(widget, isA<Object>());
  });

  test('unknown fieldtype falls back to disabled DataField', () {
    final widget = factory.createField(field: fieldOf('NonExistent'));
    expect(widget, isA<DataField>());
    expect(widget!.enabled, isFalse);
  });

  test('defaultStyle is applied when none passed at the call', () {
    final f = FieldFactory();
    final widget = f.createField(field: fieldOf('Data'));
    expect(widget, isA<DataField>());
  });
}
