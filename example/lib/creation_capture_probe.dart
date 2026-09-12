// On-device verification harness for the mobile creation capture feature.
//
// Drives the REAL offline save path — FormScreen -> OfflineRepository ->
// LocalWriter -> docs__<doctype> — on a physical device, with no server
// involved, and then reads the stored row back and shows it on screen. That is
// the part tests cannot prove: a real device clock, a real GPS fix, a real
// runtime permission prompt and a real sqflite write.
//
// Run with:
//   flutter run -t lib/creation_capture_probe.dart -d <device>
//
// FIRST-RUN SETUP: `example/android/` is gitignored (root .gitignore:53), so the
// generated manifest is local and carries no location permissions. Add these to
// example/android/app/src/main/AndroidManifest.xml or the capture silently
// records no location:
//   <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
//   <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
import 'package:flutter/material.dart';
// Test tooling: registers the VM-service extensions the flutter-skill MCP
// driver needs to inspect and tap this probe on a real device.
import 'package:flutter_skill/flutter_skill.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
// LocalWriter is not on the public surface — a real host gets one wired
// inside FrappeSDK. This probe builds the offline stack by hand precisely to
// avoid needing a server to log in to, so it reaches for the internal class.
// ignore: implementation_imports
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';

const String kProbeDoctype = 'Capture Probe';
const String kProbeChild = 'Capture Probe Member';
const String kProbeTable = 'docs__capture_probe';
const String kProbeChildTable = 'docs__capture_probe_member';

/// Mirrors how `mobile_control` provisions the two fields: hidden + read-only,
/// inserted right after `name`, on the parent AND on the child doctype.
DocField _captureField(String name, String type) =>
    DocField(fieldname: name, fieldtype: type, hidden: true, readOnly: true);

DocTypeMeta probeMeta() => DocTypeMeta(
  name: kProbeDoctype,
  fields: [
    _captureField(mobileCreatedAtField, 'Datetime'),
    _captureField(mobileLatitudeLongitudeField, 'Geolocation'),
    DocField(fieldname: 'village', fieldtype: 'Data', label: 'Village'),
    DocField(
      fieldname: 'members',
      fieldtype: 'Table',
      label: 'Members',
      options: kProbeChild,
    ),
  ],
);

DocTypeMeta probeChildMeta() => DocTypeMeta(
  name: kProbeChild,
  isTable: true,
  fields: [
    _captureField(mobileCreatedAtField, 'Datetime'),
    _captureField(mobileLatitudeLongitudeField, 'Geolocation'),
    DocField(fieldname: 'member_name', fieldtype: 'Data', label: 'Member Name'),
  ],
);

Future<void> main() async {
  FlutterSkillBinding.ensureInitialized();
  runApp(const ProbeApp());
}

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Creation Capture Probe',
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
    home: const ProbeHome(),
  );
}

class ProbeHome extends StatefulWidget {
  const ProbeHome({super.key});

  @override
  State<ProbeHome> createState() => _ProbeHomeState();
}

class _ProbeHomeState extends State<ProbeHome> {
  AppDatabase? _db;
  OfflineRepository? _repo;
  String _status = 'initialising…';
  List<Map<String, Object?>> _parentRows = const [];
  List<Map<String, Object?>> _childRows = const [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final db = await AppDatabase.getInstance(appName: 'capture_probe');
      final meta = probeMeta();
      final childMeta = probeChildMeta();
      final repo = OfflineRepository(
        db,
        localWriter: LocalWriter(db.rawDatabase, (dt) async {
          if (dt == kProbeDoctype) return meta;
          if (dt == kProbeChild) return childMeta;
          throw StateError('unexpected meta lookup: $dt');
        }),
        offlineMode: const OfflineMode(enabled: true, isPersisted: true),
        metaFetcher: (dt) async => dt == kProbeDoctype ? meta : childMeta,
      );
      await repo.ensureSchemaForClosure(
        metas: {kProbeDoctype: meta, kProbeChild: childMeta},
        childDoctypes: {kProbeChild},
      );
      setState(() {
        _db = db;
        _repo = repo;
        _status = 'ready — tap NEW RECORD';
      });
      await _refresh();
    } catch (e, st) {
      setState(() => _status = 'init failed: $e\n$st');
    }
  }

  Future<void> _refresh() async {
    final db = _db;
    if (db == null) return;
    try {
      final parents = await db.rawDatabase.query(
        kProbeTable,
        orderBy: 'local_modified DESC',
      );
      final children = await db.rawDatabase.query(kProbeChildTable);
      setState(() {
        _parentRows = parents;
        _childRows = children;
      });
    } catch (e) {
      setState(() => _status = 'read failed: $e');
    }
  }

  Future<void> _openNew() async {
    final repo = _repo;
    if (repo == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FormScreen(
          meta: probeMeta(),
          repository: repo,
          metaService: null,
          mode: FormBuilderMode.reactive,
        ),
      ),
    );
    await _refresh();
  }

  Widget _rowCard(Map<String, Object?> r, {required bool isChild}) {
    String v(String k) {
      final x = r[k];
      if (x == null) return '∅ NULL';
      final s = x.toString();
      return s.isEmpty ? '∅ EMPTY' : s;
    }

    final created = v(mobileCreatedAtField);
    final geo = v(mobileLatitudeLongitudeField);
    final ok = !created.startsWith('∅');
    final geoOk = !geo.startsWith('∅');
    return Card(
      color: ok && geoOk
          ? Colors.green.shade50
          : (ok ? Colors.amber.shade50 : Colors.red.shade50),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isChild
                  ? 'CHILD  ${v('member_name')}'
                  : 'PARENT  ${v('village')}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text('mobile_created_at:\n  $created'),
            const SizedBox(height: 2),
            Text('mobile_latitude_longitude:\n  $geo'),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Creation Capture Probe')),
    floatingActionButton: FloatingActionButton.extended(
      key: const Key('probe_new_record'),
      onPressed: _repo == null ? null : _openNew,
      icon: const Icon(Icons.add),
      label: const Text('NEW RECORD'),
    ),
    body: ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text(_status),
        const Divider(),
        Text(
          'Stored rows: ${_parentRows.length} parent / '
          '${_childRows.length} child',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        for (final r in _parentRows) _rowCard(r, isChild: false),
        for (final r in _childRows) _rowCard(r, isChild: true),
      ],
    ),
  );
}
