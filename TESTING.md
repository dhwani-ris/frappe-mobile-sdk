# Testing Guide for Frappe Mobile SDK

## Quick Start Testing

### 1. Test Using the Example App

The easiest way to test the package is using the included example app:

```bash
cd frappe_mobile_sdk/example
flutter pub get
flutter run
```

**Before running**, update `example/lib/main.dart`:
- Set your Frappe server URL in `appConfig.baseUrl`
- Configure the doctypes you want to test: `doctypes: ['Lead', 'Customer']`

### 2. Test in Your Own App

#### Step 1: Add Package Dependency

**Option A: Local Path (for development)**
```yaml
# In your app's pubspec.yaml
dependencies:
  frappe_mobile_sdk:
    path: ../frappe_mobile_sdk  # Adjust path as needed
```

**Option B: Git (for remote testing)**
```yaml
dependencies:
  frappe_mobile_sdk:
    git:
      url: https://github.com/yourusername/frappe_mobile_sdk.git
      ref: main
```

#### Step 2: Initialize SDK

```dart
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize database
  final database = await AppDatabase.getInstance();
  
  // Create app config
  final appConfig = AppConfig(
    baseUrl: 'https://your-frappe-site.com',
    doctypes: ['Lead', 'Customer'],
  );
  
  // Initialize services
  final authService = AuthService();
  authService.initialize(appConfig.baseUrl);
  
  final metaService = MetaService(authService.client!, database);
  final repository = OfflineRepository(database);
  final syncService = SyncService(authService.client!, repository, database);
  
  runApp(MyApp(
    database: database,
    authService: authService,
    metaService: metaService,
    repository: repository,
    syncService: syncService,
    appConfig: appConfig,
  ));
}
```

## Testing Individual Components

### 1. Test Authentication

```dart
// Test login
final success = await authService.login('username', 'password');
print('Login success: $success');

// Test session restore
final restored = await authService.restoreSession();
print('Session restored: $restored');

// Test logout
await authService.logout();
```

### 2. Test Metadata Fetching

```dart
// Fetch metadata for a doctype
final meta = await metaService.getMeta('Lead');
print('Fields count: ${meta.fields.length}');
print('Field names: ${meta.fields.map((f) => f.fieldname).toList()}');

// Fetch multiple doctypes
final metas = await metaService.getMetas(['Lead', 'Customer']);
print('Loaded ${metas.length} doctypes');
```

### 3. Test Offline Operations

```dart
// Create document
final doc = await repository.createDocument(
  doctype: 'Lead',
  data: {
    'lead_name': 'Test Lead',
    'email': 'test@example.com',
  },
);
print('Created document: ${doc.localId}');

// Get documents
final docs = await repository.getDocumentsByDoctype('Lead');
print('Total documents: ${docs.length}');

// Update document
final updated = await repository.updateDocumentData(
  doc.localId,
  {'lead_name': 'Updated Lead'},
);
print('Updated document status: ${updated.status}');

// Get dirty documents (need sync)
final dirtyDocs = await repository.getDirtyDocuments();
print('Dirty documents: ${dirtyDocs.length}');
```

### 4. Test Sync

```dart
// Check if online
final isOnline = await syncService.isOnline();
print('Is online: $isOnline');

// Push local changes
if (isOnline) {
  final result = await syncService.pushSync(doctype: 'Lead');
  print('Push sync: ${result.success} success, ${result.failed} failed');
}

// Pull server updates
if (isOnline) {
  final result = await syncService.pullSync(doctype: 'Lead');
  print('Pull sync: ${result.success} documents');
}

// Full sync
if (isOnline) {
  final result = await syncService.syncDoctype('Lead');
  print('Full sync: ${result.success} success, ${result.failed} failed');
}
```

### 5. Test Form Rendering

```dart
// Get metadata
final meta = await metaService.getMeta('Lead');

// Render form
FrappeFormBuilder(
  meta: meta,
  initialData: {'lead_name': 'Test'},
  onSubmit: (formData) {
    print('Form submitted: $formData');
    // Save to repository
  },
)
```

## Unit Testing

### Setup Test File

Create `test/frappe_mobile_sdk_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() {
  group('Document Model Tests', () {
    test('should create document with required fields', () {
      final doc = Document.create(
        doctype: 'Lead',
        data: {'lead_name': 'Test'},
        localId: 'test-id',
      );
      
      expect(doc.doctype, equals('Lead'));
      expect(doc.localId, equals('test-id'));
      expect(doc.status, equals('dirty'));
      expect(doc.data['lead_name'], equals('Test'));
    });
    
    test('should mark document as clean', () {
      final doc = Document.create(
        doctype: 'Lead',
        data: {'lead_name': 'Test'},
        localId: 'test-id',
      );
      
      final clean = doc.markClean();
      expect(clean.status, equals('clean'));
    });
  });
  
  group('DocField Tests', () {
    test('should parse Frappe JSON format', () {
      final json = {
        'fieldname': 'lead_name',
        'fieldtype': 'Data',
        'label': 'Lead Name',
        'reqd': 1,
        'read_only': 0,
        'hidden': 0,
      };
      
      final field = DocField.fromJson(json);
      expect(field.fieldname, equals('lead_name'));
      expect(field.fieldtype, equals('Data'));
      expect(field.reqd, isTrue);
      expect(field.readOnly, isFalse);
    });
  });
}
```

### Run Tests

```bash
flutter test
```

## Integration Testing

### Test Full Flow

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() {
  late AppDatabase database;
  late AuthService authService;
  late MetaService metaService;
  late OfflineRepository repository;
  late SyncService syncService;
  
  setUpAll(() async {
    database = await AppDatabase.getInstance();
    authService = AuthService();
    authService.initialize('https://your-frappe-site.com');
    metaService = MetaService(authService.client!, database);
    repository = OfflineRepository(database);
    syncService = SyncService(authService.client!, repository, database);
  });
  
  tearDownAll(() async {
    await database.close();
  });
  
  test('Full workflow: Login -> Fetch Meta -> Create Doc -> Sync', () async {
    // 1. Login
    final loginSuccess = await authService.login('username', 'password');
    expect(loginSuccess, isTrue);
    
    // 2. Fetch metadata
    final meta = await metaService.getMeta('Lead');
    expect(meta.fields.length, greaterThan(0));
    
    // 3. Create document
    final doc = await repository.createDocument(
      doctype: 'Lead',
      data: {'lead_name': 'Test Lead'},
    );
    expect(doc.status, equals('dirty'));
    
    // 4. Sync (if online)
    if (await syncService.isOnline()) {
      final result = await syncService.pushSync(doctype: 'Lead');
      expect(result.success, greaterThanOrEqualTo(0));
    }
  });
}
```

## Widget Testing

### Test Form Builder

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() {
  testWidgets('FrappeFormBuilder renders fields', (tester) async {
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
          body: FrappeFormBuilder(
            meta: meta,
            onSubmit: (data) {},
          ),
        ),
      ),
    );
    
    expect(find.text('Lead Name'), findsOneWidget);
    expect(find.byType(TextFormField), findsWidgets);
  });
}
```

## Debugging Tips

### 1. Check Database Contents

```dart
// List all documents
final allDocs = await repository.findAll();
print('Total documents: ${allDocs.length}');

// Check sync status
final stats = await syncService.getSyncStats();
print('Sync stats: $stats');
```

### 2. View Metadata

```dart
// Get metadata from database
final metaEntity = await database.doctypeMetaDao.findByDoctype('Lead');
if (metaEntity != null) {
  print('Meta JSON: ${metaEntity.metaJson}');
}
```

### 3. Monitor Sync

```dart
// Get dirty documents
final dirty = await repository.getDirtyDocuments();
for (final doc in dirty) {
  print('Dirty: ${doc.doctype} - ${doc.localId}');
}
```

## Common Testing Scenarios

### Scenario 1: Offline Create and Sync

```dart
// 1. Create document offline
final doc = await repository.createDocument(
  doctype: 'Lead',
  data: {'lead_name': 'Offline Lead'},
);

// 2. Verify it's dirty
expect(doc.status, equals('dirty'));

// 3. Sync when online
if (await syncService.isOnline()) {
  final result = await syncService.pushSync(doctype: 'Lead');
  expect(result.success, equals(1));
  
  // 4. Verify it's clean
  final synced = await repository.getDocumentByLocalId(doc.localId);
  expect(synced?.status, equals('clean'));
}
```

### Scenario 2: Pull Updates

```dart
// 1. Pull updates from server
final result = await syncService.pullSync(doctype: 'Lead');

// 2. Verify documents were saved
final docs = await repository.getDocumentsByDoctype('Lead');
expect(docs.length, greaterThan(0));
```

### Scenario 3: Form Validation

```dart
// Test required fields
final meta = await metaService.getMeta('Lead');
final requiredFields = meta.fields.where((f) => f.reqd).toList();
print('Required fields: ${requiredFields.map((f) => f.fieldname).toList()}');
```

## Troubleshooting Tests

### Issue: Database locked
**Solution**: Ensure database is properly closed between tests
```dart
tearDown(() async {
  await database.close();
});
```

### Issue: Metadata not found
**Solution**: Fetch metadata before using
```dart
await metaService.getMeta('Lead', forceRefresh: true);
```

### Issue: Sync fails
**Solution**: Check authentication and network
```dart
final isAuth = authService.isAuthenticated;
final isOnline = await syncService.isOnline();
print('Auth: $isAuth, Online: $isOnline');
```

## Performance Testing

### Test Large Dataset

```dart
test('Handle 1000 documents', () async {
  final stopwatch = Stopwatch()..start();
  
  // Create 1000 documents
  for (int i = 0; i < 1000; i++) {
    await repository.createDocument(
      doctype: 'Lead',
      data: {'lead_name': 'Lead $i'},
    );
  }
  
  stopwatch.stop();
  print('Created 1000 documents in ${stopwatch.elapsedMilliseconds}ms');
  
  // Query all
  stopwatch.reset()..start();
  final docs = await repository.getDocumentsByDoctype('Lead');
  stopwatch.stop();
  print('Queried ${docs.length} documents in ${stopwatch.elapsedMilliseconds}ms');
});
```

## Next Steps

1. **Run Example App**: Test the full UI flow
2. **Write Unit Tests**: Test individual components
3. **Test Sync**: Verify offline/online sync works
4. **Test Forms**: Verify dynamic form rendering
5. **Performance Test**: Test with large datasets

For more details, see the [README.md](README.md) and [SETUP.md](SETUP.md).
