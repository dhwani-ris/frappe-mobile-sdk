import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/sync/payload_assembler.dart';
import 'package:frappe_mobile_sdk/src/utils/mobile_creation_stamp.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField _f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

/// Hidden + read-only, as `mobile_control._MOBILE_CUSTOM_FIELDS` declares them.
DocField _hidden(String n, String t) =>
    DocField(fieldname: n, fieldtype: t, hidden: true, readOnly: true);

class _ChildInfo implements ChildInfo {
  @override
  final String doctype;
  @override
  final DocTypeMeta meta;
  @override
  final String tableName;
  _ChildInfo(this.doctype, this.meta, this.tableName);
}

final _parentMeta = DocTypeMeta(
  name: 'Survey',
  fields: [
    _f('village', 'Data'),
    _hidden(mobileCreatedAtField, 'Datetime'),
    _hidden(mobileLatitudeLongitudeField, 'Geolocation'),
    _f('members', 'Table', options: 'Survey Member'),
  ],
);

final _childMeta = DocTypeMeta(
  name: 'Survey Member',
  isTable: true,
  fields: [
    _f('member_name', 'Data'),
    _hidden(mobileCreatedAtField, 'Datetime'),
    _hidden(mobileLatitudeLongitudeField, 'Geolocation'),
  ],
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final s in buildParentSchemaDDL(
      _parentMeta,
      tableName: 'docs__survey',
    )) {
      await db.execute(s);
    }
    for (final s in buildChildSchemaDDL(
      _childMeta,
      tableName: 'docs__survey_member',
    )) {
      await db.execute(s);
    }
  });

  tearDown(() async => db.close());

  test(
    'both stamps survive the push strip and reach the wire, parent and child',
    () async {
      // Written the way a save writes them, then assembled the way a push
      // assembles them — end to end rather than by reading the strip list.
      final writer = await Future.value(
        LocalWriter(db, (dt) async {
          if (dt == 'Survey') return _parentMeta;
          if (dt == 'Survey Member') return _childMeta;
          throw StateError('unexpected meta lookup: $dt');
        }),
      );

      await writer.writeParent(
        parentDoctype: 'Survey',
        data: {
          'mobile_uuid': 'p1',
          'village': 'Rampur',
          mobileCreatedAtField: '2026-08-18 09:05:03',
          mobileLatitudeLongitudeField: 'PARENT_GEO',
          'members': [
            {
              'member_name': 'Asha',
              mobileCreatedAtField: '2026-08-18 09:07:11',
              mobileLatitudeLongitudeField: 'CHILD_GEO',
            },
          ],
        },
      );

      final payload = await PayloadAssembler.assemble(
        db: db,
        row: OutboxRow(
          id: 1,
          doctype: 'Survey',
          mobileUuid: 'p1',
          operation: OutboxOperation.insert,
          state: OutboxState.pending,
          retryCount: 0,
          createdAt: DateTime.utc(2026, 8, 18),
        ),
        parentMeta: _parentMeta,
        parentTable: 'docs__survey',
        childMetasByFieldname: {
          'members': _ChildInfo(
            'Survey Member',
            _childMeta,
            'docs__survey_member',
          ),
        },
        resolveServerName: (_, _) async => null,
      );

      expect(payload[mobileCreatedAtField], '2026-08-18 09:05:03');
      expect(payload[mobileLatitudeLongitudeField], 'PARENT_GEO');

      final children = payload['members'] as List;
      expect(children, hasLength(1));
      final child = children.first as Map<String, Object?>;
      expect(child[mobileCreatedAtField], '2026-08-18 09:07:11');
      expect(child[mobileLatitudeLongitudeField], 'CHILD_GEO');
    },
  );
}
