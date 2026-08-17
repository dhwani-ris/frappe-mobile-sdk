// A field that GAINS a parent column must be migrated as an add, not a
// type change.
//
// THE FAILURE THIS COMES FROM
// ---------------------------
// Swasti SWF-2026-69521 turned two answers from Table MultiSelect into Select,
// because their options are mutually exclusive:
//
//     Health Screening V3.c4s_call_successful    (9.5)
//     Health Screening Followup.health_improved  (3.5)
//
// A Table MultiSelect keeps its answers as child rows and has NO column on the
// parent table (`sqliteColumnTypeFor` returns null). A Select has one. So the
// change is not a column whose type moved — it is a column that did not exist
// and now must.
//
// MetaDiffer classified it as `typeChanged` purely because the FIELDNAME was
// present in the old meta, and MetaMigration only logs that bucket:
//
//     "typeChanged columns are not migrated yet — affected fields will keep
//      their old SQLite column type"
//
// For this shape the old "column type" is *no column*. So on every device that
// upgraded rather than reinstalled, the column was never created; the value the
// surveyor picked was dropped on write, and the push payload omitted the field
// entirely. The server then rejected the record for a missing mandatory field
// the surveyor could plainly see filled in on screen — Fahim's report of
// 2026-08-17, "Unable to sync responses getting error even though I have
// correctly added the input".
//
// A fresh install builds the table from current meta and is fine, which is why
// the on-device acceptance suite passed while real upgraded devices failed.
// That asymmetry is the whole point of this test.
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/services/meta_differ.dart';

DocTypeMeta _meta(String name, List<DocField> fields) =>
    DocTypeMeta(name: name, fields: fields);

DocField _f(String fieldname, String fieldtype) =>
    DocField(fieldname: fieldname, fieldtype: fieldtype);

void main() {
  group('a field that gains a parent column', () {
    test('Table MultiSelect -> Select is an ADD, not a type change', () {
      final diff = MetaDiffer.diff(
        oldMeta: _meta('Health Screening V3', [
          _f('name', 'Data'),
          _f('c4s_call_successful', 'Table MultiSelect'),
        ]),
        newMeta: _meta('Health Screening V3', [
          _f('name', 'Data'),
          _f('c4s_call_successful', 'Select'),
        ]),
      );

      expect(
        diff.addedFields.map((f) => f.name),
        contains('c4s_call_successful'),
        reason: 'the column does not exist yet, so it must be CREATED; '
            'left in typeChanged it is only logged and never migrated, and '
            'every value written to it is silently dropped',
      );
      expect(diff.typeChanged, isNot(contains('c4s_call_successful')));
      expect(
        diff.addedFields.firstWhere((f) => f.name == 'c4s_call_successful').sqlType,
        'TEXT',
      );
    });

    test('the same holds for Table and Password, the other column-less types', () {
      for (final oldType in ['Table', 'Password']) {
        final diff = MetaDiffer.diff(
          oldMeta: _meta('X', [_f('f', oldType)]),
          newMeta: _meta('X', [_f('f', 'Data')]),
        );
        expect(diff.addedFields.map((e) => e.name), contains('f'),
            reason: '$oldType has no parent column either');
      }
    });

    test('a Link that gains a column is registered for is_local backfill too', () {
      final diff = MetaDiffer.diff(
        oldMeta: _meta('X', [_f('parent_ref', 'Table')]),
        newMeta: _meta('X', [_f('parent_ref', 'Link')]),
      );
      expect(diff.addedFields.map((e) => e.name), contains('parent_ref'));
      expect(diff.addedIsLocalFor, contains('parent_ref'),
          reason: 'a newly created Link column needs the same is_local '
              'treatment as any other added Link, or link resolution skips it');
    });
  });

  group('genuine type changes are left alone', () {
    test('Data -> Select stays a typeChange (the column already exists)', () {
      final diff = MetaDiffer.diff(
        oldMeta: _meta('X', [_f('f', 'Data')]),
        newMeta: _meta('X', [_f('f', 'Select')]),
      );
      expect(diff.typeChanged, contains('f'));
      expect(diff.addedFields.map((e) => e.name), isNot(contains('f')));
    });

    test('Int -> Data stays a typeChange: affinity really did move', () {
      final diff = MetaDiffer.diff(
        oldMeta: _meta('X', [_f('f', 'Int')]),
        newMeta: _meta('X', [_f('f', 'Data')]),
      );
      expect(diff.typeChanged, contains('f'));
      expect(diff.addedFields.map((e) => e.name), isNot(contains('f')));
    });

    test('Select -> Table MultiSelect (losing a column) is not an add', () {
      final diff = MetaDiffer.diff(
        oldMeta: _meta('X', [_f('f', 'Select')]),
        newMeta: _meta('X', [_f('f', 'Table MultiSelect')]),
      );
      expect(diff.addedFields.map((e) => e.name), isNot(contains('f')));
      expect(diff.typeChanged, isNot(contains('f')),
          reason: 'the new type has no column, so there is nothing to migrate; '
              'the old column is simply left in place and ignored');
    });

    test('an unchanged field produces no work at all', () {
      final diff = MetaDiffer.diff(
        oldMeta: _meta('X', [_f('f', 'Select')]),
        newMeta: _meta('X', [_f('f', 'Select')]),
      );
      expect(diff.addedFields, isEmpty);
      expect(diff.typeChanged, isEmpty);
    });
  });
}
