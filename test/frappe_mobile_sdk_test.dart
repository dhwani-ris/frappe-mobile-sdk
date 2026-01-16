import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() {
  group('AppConfig Tests', () {
    test('should create AppConfig from JSON', () {
      final json = {
        'base_url': 'https://test.com',
        'doctypes': ['Lead', 'Customer'],
      };
      
      final config = AppConfig.fromJsonFile(json);
      expect(config.baseUrl, equals('https://test.com'));
      expect(config.doctypes.length, equals(2));
      expect(config.doctypes, contains('Lead'));
    });
  });

  group('Document Model Tests', () {
    test('should create document with required fields', () {
      final doc = Document.create(
        doctype: 'Lead',
        data: {'lead_name': 'Test'},
        localId: 'test-id-123',
      );
      
      expect(doc.doctype, equals('Lead'));
      expect(doc.localId, equals('test-id-123'));
      expect(doc.status, equals('dirty'));
      expect(doc.data['lead_name'], equals('Test'));
      expect(doc.serverId, isNull);
    });
    
    test('should mark document as clean', () {
      final doc = Document.create(
        doctype: 'Lead',
        data: {'lead_name': 'Test'},
        localId: 'test-id',
      );
      
      final clean = doc.markClean();
      expect(clean.status, equals('clean'));
      expect(clean.doctype, equals('Lead'));
    });
    
    test('should mark document as deleted', () {
      final doc = Document.create(
        doctype: 'Lead',
        data: {'lead_name': 'Test'},
        localId: 'test-id',
      );
      
      final deleted = doc.markDeleted();
      expect(deleted.status, equals('deleted'));
    });
    
    test('should update document data', () {
      final doc = Document.create(
        doctype: 'Lead',
        data: {'lead_name': 'Test'},
        localId: 'test-id',
      );
      
      final updated = doc.updateData({'lead_name': 'Updated', 'email': 'test@example.com'});
      expect(updated.data['lead_name'], equals('Updated'));
      expect(updated.data['email'], equals('test@example.com'));
      expect(updated.status, equals('dirty'));
    });
    
    test('should create from server document', () {
      final doc = Document.fromServer(
        doctype: 'Lead',
        serverId: 'LEAD-001',
        data: {'lead_name': 'Server Lead'},
        localId: 'local-id',
      );
      
      expect(doc.serverId, equals('LEAD-001'));
      expect(doc.status, equals('clean'));
    });
  });

  group('DocField Tests', () {
    test('should parse Frappe JSON format (int fields)', () {
      final json = {
        'fieldname': 'lead_name',
        'fieldtype': 'Data',
        'label': 'Lead Name',
        'reqd': 1,
        'read_only': 0,
        'hidden': 0,
        'precision': 2,
        'length': 100,
        'idx': 1,
      };
      
      final field = DocField.fromJson(json);
      expect(field.fieldname, equals('lead_name'));
      expect(field.fieldtype, equals('Data'));
      expect(field.reqd, isTrue);
      expect(field.readOnly, isFalse);
      expect(field.hidden, isFalse);
      expect(field.precision, equals(2));
      expect(field.length, equals(100));
      expect(field.idx, equals(1));
    });
    
    test('should parse boolean fields', () {
      final json = {
        'fieldname': 'is_active',
        'fieldtype': 'Check',
        'reqd': true,
        'readOnly': false,
      };
      
      final field = DocField.fromJson(json);
      expect(field.reqd, isTrue);
      expect(field.readOnly, isFalse);
    });
    
    test('should identify layout fields', () {
      final sectionField = DocField(
        fieldname: 'section1',
        fieldtype: 'Section Break',
      );
      expect(sectionField.isLayoutField, isTrue);
      expect(sectionField.isDataField, isFalse);
      
      final dataField = DocField(
        fieldname: 'name',
        fieldtype: 'Data',
      );
      expect(dataField.isLayoutField, isFalse);
      expect(dataField.isDataField, isTrue);
    });
    
    test('should get display label', () {
      final field1 = DocField(
        fieldname: 'lead_name',
        fieldtype: 'Data',
        label: 'Lead Name',
      );
      expect(field1.displayLabel, equals('Lead Name'));
      
      final field2 = DocField(
        fieldname: 'email',
        fieldtype: 'Data',
      );
      expect(field2.displayLabel, equals('email'));
    });
  });

  group('DocTypeMeta Tests', () {
    test('should create DocTypeMeta with fields', () {
      final meta = DocTypeMeta(
        name: 'Lead',
        label: 'Lead',
        fields: [
          DocField(fieldname: 'lead_name', fieldtype: 'Data'),
          DocField(fieldname: 'email', fieldtype: 'Data'),
        ],
      );
      
      expect(meta.name, equals('Lead'));
      expect(meta.fields.length, equals(2));
    });
    
    test('should get field by fieldname', () {
      final meta = DocTypeMeta(
        name: 'Lead',
        fields: [
          DocField(fieldname: 'lead_name', fieldtype: 'Data'),
          DocField(fieldname: 'email', fieldtype: 'Data'),
        ],
      );
      
      final field = meta.getField('lead_name');
      expect(field, isNotNull);
      expect(field?.fieldname, equals('lead_name'));
      
      final notFound = meta.getField('nonexistent');
      expect(notFound, isNull);
    });
    
    test('should filter data fields', () {
      final meta = DocTypeMeta(
        name: 'Lead',
        fields: [
          DocField(fieldname: 'lead_name', fieldtype: 'Data'),
          DocField(fieldname: 'section1', fieldtype: 'Section Break'),
          DocField(fieldname: 'email', fieldtype: 'Data'),
        ],
      );
      
      final dataFields = meta.dataFields;
      expect(dataFields.length, equals(2));
      expect(dataFields.map((f) => f.fieldname), containsAll(['lead_name', 'email']));
    });
  });
}
