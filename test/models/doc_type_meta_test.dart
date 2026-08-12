import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';

DocField f(String n, String t, {bool inListView = false}) =>
    DocField(fieldname: n, fieldtype: t, label: n, inListView: inListView);

void main() {
  group('DocTypeMeta.fromJson — istable variants', () {
    test('istable=1 (int) sets isTable=true', () {
      final m = DocTypeMeta.fromJson({'name': 'X', 'fields': [], 'istable': 1});
      expect(m.isTable, isTrue);
    });

    test('istable=0 (int) sets isTable=false', () {
      final m = DocTypeMeta.fromJson({'name': 'X', 'fields': [], 'istable': 0});
      expect(m.isTable, isFalse);
    });

    test('istable=true (bool) sets isTable=true', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        'istable': true,
      });
      expect(m.isTable, isTrue);
    });

    test('isTable camelCase key also works', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        'isTable': true,
      });
      expect(m.isTable, isTrue);
    });

    test('isTable camelCase int=1 works', () {
      final m = DocTypeMeta.fromJson({'name': 'X', 'fields': [], 'isTable': 1});
      expect(m.isTable, isTrue);
    });
  });

  group('DocTypeMeta.fromJson — search_fields', () {
    test('comma-separated string is split and trimmed', () {
      final m = DocTypeMeta.fromJson({
        'name': 'Customer',
        'fields': [],
        'search_fields': 'customer_name, mobile_no, email_id',
      });
      expect(m.searchFields, ['customer_name', 'mobile_no', 'email_id']);
    });

    test('empty search_fields string yields null', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        'search_fields': '',
      });
      expect(m.searchFields, isNull);
    });

    test('absent search_fields yields null', () {
      final m = DocTypeMeta.fromJson({'name': 'X', 'fields': []});
      expect(m.searchFields, isNull);
    });
  });

  group('DocTypeMeta.fromJson — autoname', () {
    test('autoname stored when non-empty', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        'autoname': 'field:mobile_uuid',
      });
      expect(m.autoname, 'field:mobile_uuid');
    });

    test('empty autoname stored as null', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        'autoname': '',
      });
      expect(m.autoname, isNull);
    });
  });

  group('DocTypeMeta.fromJson — sort_order normalization', () {
    test('"DESC" → "desc"', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        'sort_order': 'DESC',
      });
      expect(m.sortOrder, 'desc');
    });

    test('"ASC" → "asc"', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        'sort_order': 'ASC',
      });
      expect(m.sortOrder, 'asc');
    });

    test('absent sort_order yields null', () {
      final m = DocTypeMeta.fromJson({'name': 'X', 'fields': []});
      expect(m.sortOrder, isNull);
    });
  });

  group('DocTypeMeta.isSubmittable', () {
    test('is_submittable=1 returns true', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        'is_submittable': 1,
      });
      expect(m.isSubmittable, isTrue);
    });

    test('is_submittable=true returns true', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        'is_submittable': true,
      });
      expect(m.isSubmittable, isTrue);
    });

    test('absent is_submittable returns false', () {
      final m = DocTypeMeta.fromJson({'name': 'X', 'fields': []});
      expect(m.isSubmittable, isFalse);
    });
  });

  group('DocTypeMeta.hasPermission', () {
    test('returns true when no metaData', () {
      final m = DocTypeMeta(name: 'X', fields: const []);
      expect(m.hasPermission('read'), isTrue);
    });

    test('returns true when permissions list is empty', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        'permissions': <dynamic>[],
      });
      expect(m.hasPermission('read'), isTrue);
    });

    test('grants when role is in userRoles', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        'permissions': [
          {'role': 'Manager', 'read': 1, 'permlevel': 0},
        ],
      });
      expect(m.hasPermission('read', userRoles: ['Manager']), isTrue);
    });

    test('denies when none of the userRoles match', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        'permissions': [
          {'role': 'Manager', 'read': 1, 'permlevel': 0},
        ],
      });
      expect(m.hasPermission('read', userRoles: ['Employee']), isFalse);
    });

    test('grants when no userRoles provided and any perm row allows', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        'permissions': [
          {'role': 'Manager', 'read': 1, 'permlevel': 0},
        ],
      });
      expect(m.hasPermission('read'), isTrue);
    });

    test('skips permlevel != 0 rows', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        'permissions': [
          {'role': 'Manager', 'read': 1, 'permlevel': 1},
        ],
      });
      // permlevel 1 is ignored, no permlevel 0 row → deny
      expect(m.hasPermission('read', userRoles: ['Manager']), isFalse);
    });
  });

  group('DocTypeMeta.hasWorkflow / workflowStateField', () {
    test('hasWorkflow false when __workflow_docs absent', () {
      final m = DocTypeMeta.fromJson({'name': 'X', 'fields': []});
      expect(m.hasWorkflow, isFalse);
      expect(m.workflowStateField, isNull);
    });

    test('hasWorkflow false when __workflow_docs is empty list', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        '__workflow_docs': <dynamic>[],
      });
      expect(m.hasWorkflow, isFalse);
    });

    test('hasWorkflow true and workflowStateField extracted', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        '__workflow_docs': [
          {'workflow_state_field': 'status'},
        ],
      });
      expect(m.hasWorkflow, isTrue);
      expect(m.workflowStateField, 'status');
    });

    test('workflowStateField null when first entry has no field', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        '__workflow_docs': [<String, dynamic>{}],
      });
      expect(m.workflowStateField, isNull);
    });
  });

  group('DocTypeMeta.normFieldNames', () {
    test('empty when no titleField and no searchFields', () {
      final m = DocTypeMeta(name: 'X', fields: const []);
      expect(m.normFieldNames, isEmpty);
    });

    test('includes titleField', () {
      final m = DocTypeMeta(
        name: 'X',
        fields: const [],
        titleField: 'customer_name',
      );
      expect(m.normFieldNames, contains('customer_name'));
    });

    test('includes titleField and searchFields without duplicates', () {
      final m = DocTypeMeta(
        name: 'X',
        fields: const [],
        titleField: 'customer_name',
        searchFields: ['customer_name', 'mobile_no'],
      );
      expect(m.normFieldNames, {'customer_name', 'mobile_no'});
    });
  });

  group('DocTypeMeta — computed field lists', () {
    test('listViewFields returns inListView=true fields sorted by idx', () {
      final m = DocTypeMeta(
        name: 'Customer',
        fields: [
          DocField(
            fieldname: 'b',
            fieldtype: 'Data',
            label: 'B',
            inListView: true,
            idx: 2,
          ),
          DocField(
            fieldname: 'a',
            fieldtype: 'Data',
            label: 'A',
            inListView: true,
            idx: 1,
          ),
          DocField(
            fieldname: 'c',
            fieldtype: 'Data',
            label: 'C',
            inListView: false,
            idx: 3,
          ),
        ],
      );
      final list = m.listViewFields;
      expect(list.map((f) => f.fieldname), ['a', 'b']);
    });

    test('layoutFields returns Section Break and Column Break fields', () {
      final m = DocTypeMeta(
        name: 'X',
        fields: [
          DocField(fieldname: 'sec', fieldtype: 'Section Break', label: 'S'),
          DocField(fieldname: 'col', fieldtype: 'Column Break', label: 'C'),
          DocField(fieldname: 'dat', fieldtype: 'Data', label: 'D'),
        ],
      );
      final layout = m.layoutFields;
      expect(layout.map((f) => f.fieldname), containsAll(['sec', 'col']));
      expect(layout.map((f) => f.fieldname), isNot(contains('dat')));
    });
  });

  group('DocTypeMeta.translatedDoctype', () {
    test('translated_doctype=1 (int) → true', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        'translated_doctype': 1,
      });
      expect(m.translatedDoctype, isTrue);
    });

    test('translated_doctype=true (bool) → true', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        'translated_doctype': true,
      });
      expect(m.translatedDoctype, isTrue);
    });

    test('translated_doctype=0 → false', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        'translated_doctype': 0,
      });
      expect(m.translatedDoctype, isFalse);
    });

    test('translated_doctype absent → false', () {
      final m = DocTypeMeta.fromJson({'name': 'X', 'fields': []});
      expect(m.translatedDoctype, isFalse);
    });
  });

  group('DocTypeMeta.isSingle', () {
    test('issingle=1 (int) → true', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        'issingle': 1,
      });
      expect(m.isSingle, isTrue);
    });

    test('issingle=true (bool) → true', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [],
        'issingle': true,
      });
      expect(m.isSingle, isTrue);
    });

    test('issingle absent → false', () {
      final m = DocTypeMeta.fromJson({'name': 'X', 'fields': []});
      expect(m.isSingle, isFalse);
    });
  });

  group('DocField.isVirtual', () {
    test('is_virtual=1 (int) → true', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [
          {'fieldname': 'a', 'fieldtype': 'Data', 'is_virtual': 1},
        ],
      });
      expect(m.fields.single.isVirtual, isTrue);
    });

    test('is_virtual=true (bool) and "1" (String) → true', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [
          {'fieldname': 'a', 'fieldtype': 'Data', 'is_virtual': true},
          {'fieldname': 'b', 'fieldtype': 'Data', 'is_virtual': '1'},
        ],
      });
      expect(m.fields.map((f) => f.isVirtual), everyElement(isTrue));
    });

    test('is_virtual=0 / absent → false (default preserves old behavior)', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [
          {'fieldname': 'a', 'fieldtype': 'Data', 'is_virtual': 0},
          {'fieldname': 'b', 'fieldtype': 'Data'},
        ],
      });
      expect(m.fields.map((f) => f.isVirtual), everyElement(isFalse));
    });

    test('camelCase isVirtual key is accepted', () {
      final m = DocTypeMeta.fromJson({
        'name': 'X',
        'fields': [
          {'fieldname': 'a', 'fieldtype': 'Data', 'isVirtual': 1},
        ],
      });
      expect(m.fields.single.isVirtual, isTrue);
    });

    test('survives a toJson/fromJson round-trip via the meta cache', () {
      // MetaService persists DocTypeMeta.toJson() into the local meta cache,
      // so a dropped key would lose the flag on the next cold start.
      final original = DocTypeMeta(
        name: 'X',
        fields: [
          DocField(fieldname: 'real', fieldtype: 'Currency'),
          DocField(fieldname: 'virt', fieldtype: 'Currency', isVirtual: true),
        ],
      );
      final back = DocTypeMeta.fromJson(original.toJson());

      expect(back.fields.length, 2);
      expect(back.fields[0].isVirtual, isFalse);
      expect(back.fields[1].isVirtual, isTrue);
      // The new key must not disturb any neighbouring field.
      expect(back.fields[1].fieldname, 'virt');
      expect(back.fields[1].fieldtype, 'Currency');
    });

    test('other DocField flags still round-trip alongside is_virtual', () {
      final original = DocTypeMeta(
        name: 'X',
        fields: [
          DocField(
            fieldname: 'a',
            fieldtype: 'Data',
            label: 'A',
            reqd: true,
            readOnly: true,
            hidden: true,
            inListView: true,
            searchIndex: true,
            isVirtual: true,
          ),
        ],
      );
      final back = DocTypeMeta.fromJson(original.toJson()).fields.single;

      expect(back.label, 'A');
      expect(back.reqd, isTrue);
      expect(back.readOnly, isTrue);
      expect(back.hidden, isTrue);
      expect(back.inListView, isTrue);
      expect(back.searchIndex, isTrue);
      expect(back.isVirtual, isTrue);
    });
  });
}
