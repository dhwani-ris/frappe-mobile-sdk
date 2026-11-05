// SyncStatusScreen — pending-document list, grouping, push-sync outcomes and
// error surfacing, driven by in-memory fakes of the two services it calls.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/document.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/services/sync_service.dart';
import 'package:frappe_mobile_sdk/src/ui/sync_status_screen.dart';

class _FakeRepo extends Fake implements OfflineRepository {
  List<Document> docs = [];
  Object? error;
  Completer<List<Document>>? gate;
  int loads = 0;

  @override
  Future<List<Document>> getDirtyDocuments({String? doctype}) async {
    loads++;
    if (gate != null) return gate!.future;
    if (error != null) throw error!;
    return List.of(docs);
  }
}

class _FakeSync extends Fake implements SyncService {
  final List<String?> calls = [];
  SyncResult Function(String? doctype)? result;
  Object? error;
  Completer<SyncResult>? gate;

  @override
  Future<SyncResult> pushSync({String? doctype}) async {
    calls.add(doctype);
    if (gate != null) return gate!.future;
    if (error != null) throw error!;
    return result?.call(doctype) ?? SyncResult(0, 0, 0, null);
  }
}

Document _doc(
  String doctype,
  String localId, {
  String? serverId,
  String status = 'dirty',
}) => Document(
  localId: localId,
  doctype: doctype,
  serverId: serverId,
  data: const {},
  status: status,
  modified: 0,
);

// The per-doctype "Sync" buttons are `TextButton.icon`. Before Flutter 3.41
// that returned a private TextButton subclass, which `find.byType(TextButton)`
// (and so `find.widgetWithText(TextButton, ...)`) does not match.
Finder _syncButtons() => find.ancestor(
  of: find.text('Sync'),
  matching: find.byWidgetPredicate((w) => w is TextButton),
);

Future<void> _pump(WidgetTester tester, _FakeRepo repo, _FakeSync sync) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SyncStatusScreen(syncService: sync, repository: repo),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shows a spinner until the pending list resolves', (
    tester,
  ) async {
    final repo = _FakeRepo()..gate = Completer();
    await _pump(tester, repo, _FakeSync());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    repo.gate!.complete(const []);
    await tester.pump();
    expect(find.text('All documents synced'), findsOneWidget);
    expect(find.text('No pending changes'), findsOneWidget);
  });

  testWidgets('groups rows under one header per doctype, with row kinds', (
    tester,
  ) async {
    final repo = _FakeRepo()
      ..docs = [
        _doc('Task', 'uuid-new'),
        _doc('Task', 'uuid-2', serverId: 'TASK-0002'),
        _doc('Task', 'uuid-3', serverId: 'TASK-0003', status: 'deleted'),
        _doc('ToDo', 'uuid-9'),
      ];
    await _pump(tester, repo, _FakeSync());

    // One header per doctype: "Task" and "ToDo" each once.
    expect(find.text('Task'), findsOneWidget);
    expect(find.text('ToDo'), findsOneWidget);
    expect(_syncButtons(), findsNWidgets(2));

    // New (no server id): title is the local id, "not synced" subtitle.
    expect(find.text('uuid-new'), findsOneWidget);
    expect(find.text('New document (not synced)'), findsNWidgets(2));
    // Server-known, dirty: title is the server name.
    expect(find.text('TASK-0002'), findsOneWidget);
    expect(find.text('Pending update'), findsOneWidget);
    // Deleted.
    expect(find.text('Pending deletion'), findsOneWidget);
    expect(find.byIcon(Icons.delete), findsOneWidget);
    expect(find.byIcon(Icons.add_circle), findsNWidgets(2));
    expect(find.byIcon(Icons.edit), findsOneWidget);
  });

  testWidgets('a load failure is reported in the status banner', (
    tester,
  ) async {
    final repo = _FakeRepo()..error = StateError('db locked');
    await _pump(tester, repo, _FakeSync());
    expect(find.textContaining('Error loading documents:'), findsOneWidget);
    expect(find.textContaining('db locked'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('refresh reloads the list', (tester) async {
    final repo = _FakeRepo();
    await _pump(tester, repo, _FakeSync());
    expect(repo.loads, 1);
    repo.docs = [_doc('Task', 'uuid-late')];
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    expect(repo.loads, 2);
    expect(find.text('uuid-late'), findsOneWidget);
  });

  testWidgets('Sync All: success summary, snackbar, list reloaded', (
    tester,
  ) async {
    final repo = _FakeRepo()..docs = [_doc('Task', 'uuid-1')];
    final sync = _FakeSync()..result = (_) => SyncResult(1, 0, 1, null);
    await _pump(tester, repo, sync);
    repo.docs = [];
    await tester.tap(find.text('Sync All Documents'));
    await tester.pump();
    await tester.pump();
    expect(sync.calls, [null]);
    expect(find.text('Sync completed: 1 succeeded, 0 failed'), findsOneWidget);
    expect(find.text('Successfully synced 1 document(s)'), findsOneWidget);
    expect(find.text('All documents synced'), findsOneWidget);
    expect(repo.loads, 2);
  });

  testWidgets('while syncing, both sync entry points are disabled', (
    tester,
  ) async {
    final repo = _FakeRepo()..docs = [_doc('Task', 'uuid-1')];
    final sync = _FakeSync()..gate = Completer();
    await _pump(tester, repo, sync);
    await tester.tap(find.text('Sync All Documents'));
    await tester.pump();
    expect(find.text('Syncing...'), findsOneWidget);
    final all = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text('Sync All Documents'),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    );
    expect(all.onPressed, isNull);
    final perDoctype = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text('Sync'),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    );
    expect(perDoctype.onPressed, isNull);
    // The refresh action becomes a spinner.
    expect(find.byIcon(Icons.refresh), findsNothing);

    sync.gate!.complete(SyncResult(0, 0, 0, null));
    await tester.pump();
    await tester.pump();
    expect(sync.calls, hasLength(1));
    // Nothing succeeded, nothing failed: no snackbar.
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('per-doctype Sync pushes only that doctype', (tester) async {
    final repo = _FakeRepo()
      ..docs = [_doc('Task', 'uuid-1'), _doc('ToDo', 'uuid-2')];
    final sync = _FakeSync()..result = (_) => SyncResult(1, 0, 1, null);
    await _pump(tester, repo, sync);
    await tester.tap(_syncButtons().last);
    await tester.pump();
    await tester.pump();
    expect(sync.calls, ['ToDo']);
    expect(find.text('Successfully synced 1 document(s)'), findsOneWidget);
  });

  testWidgets('push errors open a dialog listing each failure', (tester) async {
    final repo = _FakeRepo()..docs = [_doc('Task', 'uuid-1')];
    final sync = _FakeSync()
      ..result = (_) => SyncResult(
        0,
        1,
        1,
        null,
        errors: [
          SyncError(
            documentId: 'uuid-1',
            doctype: 'Task',
            operation: 'insert',
            errorMessage: 'Subject is mandatory',
            timestamp: DateTime(2026, 1, 2, 3, 4, 5),
          ),
        ],
      );
    await _pump(tester, repo, sync);
    await tester.tap(find.text('Sync All Documents'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Sync Errors'), findsOneWidget);
    expect(find.text('INSERT: Task'), findsOneWidget);
    expect(find.text('Document: uuid-1'), findsOneWidget);
    expect(find.text('Subject is mandatory'), findsOneWidget);
    expect(find.text('Time: 2026-01-02 03:04:05'), findsOneWidget);
    expect(find.text('Sync completed: 0 succeeded, 1 failed'), findsOneWidget);
    // No success snackbar when there were errors.
    expect(find.textContaining('Successfully synced'), findsNothing);

    await tester.tap(find.text('Close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Sync Errors'), findsNothing);
  });

  testWidgets('per-doctype push errors also open the dialog', (tester) async {
    final repo = _FakeRepo()..docs = [_doc('Task', 'uuid-1')];
    final sync = _FakeSync()
      ..result = (dt) => SyncResult(
        0,
        1,
        1,
        null,
        errors: [
          SyncError(
            documentId: 'uuid-1',
            doctype: dt!,
            operation: 'update',
            errorMessage: 'Row changed on server',
          ),
        ],
      );
    await _pump(tester, repo, sync);
    await tester.tap(_syncButtons());
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(sync.calls, ['Task']);
    expect(find.text('UPDATE: Task'), findsOneWidget);
    expect(find.text('Row changed on server'), findsOneWidget);
  });

  testWidgets('a thrown push error is shown in banner and snackbar', (
    tester,
  ) async {
    final repo = _FakeRepo()..docs = [_doc('Task', 'uuid-1')];
    final sync = _FakeSync()..error = StateError('offline');
    await _pump(tester, repo, sync);
    await tester.tap(find.text('Sync All Documents'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Sync failed:'), findsOneWidget);
    expect(find.textContaining('Sync error:'), findsOneWidget);
    // The user can retry.
    final all = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text('Sync All Documents'),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    );
    expect(all.onPressed, isNotNull);
  });

  testWidgets('a thrown per-doctype push error is surfaced too', (
    tester,
  ) async {
    final repo = _FakeRepo()..docs = [_doc('Task', 'uuid-1')];
    final sync = _FakeSync()..error = StateError('timeout');
    await _pump(tester, repo, sync);
    await tester.tap(_syncButtons());
    await tester.pump();
    await tester.pump();
    expect(sync.calls, ['Task']);
    expect(find.textContaining('Sync failed:'), findsOneWidget);
    expect(find.textContaining('timeout'), findsWidgets);
  });

  testWidgets(
    'leaving the screen before the pending list loads is safe',
    (tester) async {
      // BUG SDK2-7 (P3): sync_status_screen.dart:44 (and :50, :68, :93, :119,
      // :144) call setState after an await with no `mounted` check. Popping
      // the screen while getDirtyDocuments (a full docs__ scan) is still
      // running throws "setState() called after dispose()". Same class as
      // SDK-12/SDK-21, different screen.
      final repo = _FakeRepo()..gate = Completer();
      await _pump(tester, repo, _FakeSync());
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      repo.gate!.complete(const []);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
    skip: true, // BUG SDK2-7: setState after dispose
  );

  testWidgets(
    'leaving the screen while a push is in flight is safe',
    (tester) async {
      // BUG SDK2-7: same root cause on the push path (:68).
      final repo = _FakeRepo();
      final sync = _FakeSync()..gate = Completer();
      await _pump(tester, repo, sync);
      await tester.tap(find.text('Sync All Documents'));
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      sync.gate!.complete(SyncResult(1, 0, 1, null));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
    skip: true, // BUG SDK2-7: setState after dispose
  );
}
