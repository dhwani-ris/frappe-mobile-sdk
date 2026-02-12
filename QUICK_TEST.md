# Quick Test Guide

## 1. Run Example App (Fastest Way)

```bash
cd frappe_mobile_sdk/example

# Edit example/lib/main.dart and set:
# - baseUrl: 'https://your-frappe-site.com'
# - doctypes: ['Lead', 'Customer']

flutter pub get
flutter run
```

## 2. Test in Dart DevTools

```bash
# Run tests
cd frappe_mobile_sdk
flutter test

# Run with coverage
flutter test --coverage
```

## 3. Quick Manual Test Script

Create `test/manual_test.dart`:

```dart
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() async {
  print('🧪 Testing Frappe Mobile SDK\n');
  
  // Test 1: AppConfig
  print('1. Testing AppConfig...');
  final config = AppConfig(
    baseUrl: 'https://test.com',
    doctypes: ['Lead'],
  );
  print('   ✅ Config created: ${config.baseUrl}');
  
  // Test 2: Document
  print('2. Testing Document...');
  final doc = Document.create(
    doctype: 'Lead',
    data: {'lead_name': 'Test'},
    localId: 'test-123',
  );
  print('   ✅ Document created: ${doc.localId}');
  print('   ✅ Status: ${doc.status}');
  
  // Test 3: DocField
  print('3. Testing DocField...');
  final field = DocField.fromJson({
    'fieldname': 'lead_name',
    'fieldtype': 'Data',
    'reqd': 1,
  });
  print('   ✅ Field parsed: ${field.fieldname}');
  print('   ✅ Required: ${field.reqd}');
  
  print('\n✅ All basic tests passed!');
}
```

Run it:
```bash
dart test/manual_test.dart
```

## 4. Test Database Operations

```dart
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() async {
  // Initialize database
  final db = await AppDatabase.getInstance();
  
  // Test metadata storage
  final metaEntity = DoctypeMetaEntity(
    doctype: 'Lead',
    metaJson: '{"name": "Lead"}',
  );
  await db.doctypeMetaDao.insertDoctypeMeta(metaEntity);
  print('✅ Metadata inserted');
  
  // Test document storage
  final docEntity = DocumentEntity(
    localId: 'test-123',
    doctype: 'Lead',
    dataJson: '{"lead_name": "Test"}',
    status: 'dirty',
    modified: DateTime.now().millisecondsSinceEpoch,
  );
  await db.documentDao.insertDocument(docEntity);
  print('✅ Document inserted');
  
  // Query back
  final retrieved = await db.documentDao.findByLocalId('test-123');
  print('✅ Document retrieved: ${retrieved?.doctype}');
  
  await db.close();
}
```

## 5. Test Form Rendering (Widget Test)

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() {
  testWidgets('Form renders correctly', (tester) async {
    final meta = DocTypeMeta(
      name: 'Lead',
      fields: [
        DocField(
          fieldname: 'lead_name',
          fieldtype: 'Data',
          label: 'Lead Name',
          reqd: true,
        ),
      ],
    );
    
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(meta: meta, onSubmit: (_) {}),
        ),
      ),
    );
    
    expect(find.text('Lead Name'), findsOneWidget);
  });
}
```

## Checklist

- [ ] Example app runs without errors
- [ ] Can login to Frappe server
- [ ] Metadata loads correctly
- [ ] Can create documents offline
- [ ] Can sync documents (if online)
- [ ] Forms render correctly
- [ ] All unit tests pass

## Common Issues


**Issue**: Database errors
- Delete app and reinstall
- Check database version matches

**Issue**: Sync fails
- Check internet connection
- Verify authentication token
- Check server URL is correct
