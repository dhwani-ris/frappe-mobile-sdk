import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../database/daos/doctype_meta_dao.dart';
import '../database/table_name.dart';
import '../models/meta_resolver.dart';
import 'filter_parser.dart';
import 'link_decorator.dart';
import 'query_result.dart';

typedef IsOnlineFn = bool Function();

/// Background fetcher that refreshes the local store for a given query.
/// Wired at SDK init to a single-doctype pull adapter — typically
/// `PullEngine.fetchAndApplyOne`. Receives a copy of the request params
/// so it can shape the upstream call (filters, paging) however it likes.
typedef BackgroundFetcher = Future<void> Function(
  String doctype,
  Map<String, Object?> params,
);

/// The single read path for the offline-first SDK. Spec §6.1–§6.3.
///
/// Every offline read — `OfflineRepository.query`, Link picker,
/// `fetch_from`, list screens, direct consumer queries — funnels through
/// `resolve(...)`. The flow:
///
/// 1. **DB-first**: build a parameter-bound `SELECT` via [FilterParser]
///    and run it. This is the value the caller sees.
/// 2. **Decorate**: every Link / Dynamic Link value gets a
///    `<field>__display` companion via [LinkDecorator].
/// 3. **Background refresh**: if `isOnline()` is true, schedule a single
///    upstream refresh via `backgroundFetch`. Concurrent calls with the
///    same request key are deduped — only one background fetch runs.
/// 4. Return [QueryResult] immediately; the background refresh runs in
///    parallel and any rows it pulls land in the same `docs__<doctype>`
///    table on the next user-driven re-read.
///
/// Spec §6.2 step 2 describes a "precedence" rule (group rows by
/// `server_name ?? mobile_uuid`, prefer dirty/blocked/conflict over
/// synced). It is a no-op against our schema: every `docs__<doctype>`
/// row is a single logical doc — the local-edit case mutates the
/// existing row's `sync_status` in-place rather than inserting a
/// shadow. PullApply's UPSERT-by-server_name preserves this invariant
/// (Spec §5.1, P3). The resolver therefore relies on row uniqueness
/// and tags origin from `sync_status` directly.
class UnifiedResolver {
  final Database db;
  final DoctypeMetaDao metaDao;
  final IsOnlineFn isOnline;
  final BackgroundFetcher backgroundFetch;
  final MetaResolverFn metaResolver;

  /// Active background refreshes keyed by request hash. Holds the
  /// in-flight Future so concurrent callers can `await` the same one
  /// without firing a duplicate request.
  final Map<String, Future<void>> _inflightBg = {};

  UnifiedResolver({
    required this.db,
    required this.metaDao,
    required this.isOnline,
    required this.backgroundFetch,
    required this.metaResolver,
  });

  Future<QueryResult<Map<String, Object?>>> resolve({
    required String doctype,
    List<List> filters = const [],
    List<List> orFilters = const [],
    String? orderBy,
    int page = 0,
    int pageSize = 50,
    bool includeFailed = false,
  }) async {
    final meta = await metaResolver(doctype);
    final tableName = await metaDao.getTableName(doctype) ??
        normalizeDoctypeTableName(doctype);

    // For child tables, Frappe link_filters reference Frappe's virtual
    // `parent` field (server_name of parent). The local schema stores
    // the parent's mobile_uuid in `parent_uuid` instead. Translate
    // before handing off to FilterParser so the column whitelist check
    // passes and the lookup finds both offline and synced child rows.
    final effectiveFilters = meta.isTable
        ? await _translateParentFilters(filters, tableName)
        : <List>[...filters];
    final effectiveOrFilters = meta.isTable
        ? await _translateParentFilters(orFilters, tableName)
        : <List>[...orFilters];

    // Child tables (isTable=true) have no sync_status column — skip.
    if (!includeFailed && !meta.isTable) {
      effectiveFilters.add([
        'sync_status',
        'not in',
        const ['failed'],
      ]);
    }

    final parsed = FilterParser.toSql(
      meta: meta,
      tableName: tableName,
      filters: effectiveFilters,
      orFilters: effectiveOrFilters,
      orderBy: orderBy,
      page: page,
      pageSize: pageSize,
    );
    final rawRows = await db.rawQuery(parsed.sql, parsed.params);
    final rows = await Future.wait(rawRows.map((r) async {
      return LinkDecorator.decorate(
        db: db,
        parentMeta: meta,
        row: Map<String, Object?>.from(r),
        targetMetaResolver: metaResolver,
      );
    }));

    if (isOnline()) {
      _scheduleBackgroundRefresh(
        doctype: doctype,
        filters: filters,
        orFilters: orFilters,
        orderBy: orderBy,
        page: page,
        pageSize: pageSize,
      );
    }

    final breakdown = <RowOrigin, int>{};
    for (final r in rows) {
      final status = (r['sync_status'] as String?) ?? 'synced';
      final origin = status == 'synced' ? RowOrigin.server : RowOrigin.local;
      breakdown[origin] = (breakdown[origin] ?? 0) + 1;
    }

    return QueryResult<Map<String, Object?>>(
      rows: rows,
      hasMore: rows.length == pageSize,
      returnedCount: rows.length,
      originBreakdown: breakdown,
    );
  }

  void _scheduleBackgroundRefresh({
    required String doctype,
    required List<List> filters,
    required List<List> orFilters,
    required String? orderBy,
    required int page,
    required int pageSize,
  }) {
    final key = _requestKey(doctype, filters, orFilters, orderBy, page);
    _inflightBg.putIfAbsent(key, () async {
      // Yield once to the event loop so concurrently-pending callers
      // (parallel `resolve` calls) get a chance to register against the
      // same in-flight key before this Future resolves and the entry is
      // removed. Without this yield, a trivially-async backgroundFetch
      // would complete before the second caller's putIfAbsent runs and
      // dedup would silently fail.
      await Future<void>.delayed(Duration.zero);
      try {
        await backgroundFetch(doctype, {
          'filters': filters,
          'or_filters': orFilters,
          'order_by': orderBy,
          'limit_start': page * pageSize,
          'limit_page_length': pageSize,
        });
      } catch (_) {
        // Background refresh is best-effort. Failures are observed by
        // the consumer through SyncStateNotifier (PullEngine emits its
        // own per-doctype error state) and don't affect the foreground
        // read that already returned.
      } finally {
        _inflightBg.remove(key);
      }
    });
  }

  /// Translates Frappe's virtual `parent` column references into
  /// `parent_uuid` lookups for child-table queries.
  ///
  /// Frappe link_filters use `parent` (the server_name of the parent row),
  /// but the local child schema stores the parent's mobile_uuid in
  /// `parent_uuid`. For offline records the Link picker returns mobile_uuid
  /// as the selected value, so a direct `parent_uuid = <value>` match is
  /// tried first. For synced parents the server_name is looked up in every
  /// distinct parent-doctype table to find the corresponding mobile_uuid.
  Future<List<List>> _translateParentFilters(
    List<List> filters,
    String childTableName,
  ) async {
    final result = <List>[];
    for (final f in filters) {
      if (f.length == 3 && f[0] == 'parent') {
        final op = (f[1] as String).toLowerCase().trim();
        final value = f[2]?.toString() ?? '';
        if (op == '=' && value.isNotEmpty) {
          final resolved =
              await _resolveParentUuid(childTableName, value) ?? value;
          result.add(['parent_uuid', '=', resolved]);
        } else {
          // For operators other than '=', map column name only.
          result.add(['parent_uuid', f[1], f[2]]);
        }
      } else {
        result.add(List.from(f));
      }
    }
    return result;
  }

  /// Returns the `parent_uuid` that corresponds to [value] in [childTable].
  ///
  /// Strategy:
  /// 1. Direct match — value is already a mobile_uuid stored in parent_uuid.
  /// 2. For each distinct parent_doctype in the child table, look up the
  ///    parent's mobile_uuid via server_name = [value].
  Future<String?> _resolveParentUuid(
    String childTable,
    String value,
  ) async {
    // 1. Direct match (offline case: value IS the mobile_uuid).
    final direct = await db.rawQuery(
      'SELECT 1 FROM $childTable WHERE parent_uuid = ? LIMIT 1',
      [value],
    );
    if (direct.isNotEmpty) return value;

    // 2. Resolve server_name → mobile_uuid via each distinct parent doctype.
    final parentDoctypeRows = await db.rawQuery(
      'SELECT DISTINCT parent_doctype FROM $childTable WHERE parent_doctype IS NOT NULL',
    );
    for (final pdRow in parentDoctypeRows) {
      final parentDoctype = pdRow['parent_doctype'] as String?;
      if (parentDoctype == null || parentDoctype.isEmpty) continue;
      final parentTable = normalizeDoctypeTableName(parentDoctype);
      final parentRows = await db.rawQuery(
        'SELECT mobile_uuid FROM $parentTable WHERE server_name = ? LIMIT 1',
        [value],
      );
      if (parentRows.isNotEmpty) {
        return parentRows.first['mobile_uuid'] as String?;
      }
    }
    return null;
  }

  String _requestKey(
    String doctype,
    List<List> filters,
    List<List> orFilters,
    String? orderBy,
    int page,
  ) {
    final raw = jsonEncode({
      'dt': doctype,
      'f': filters,
      'of': orFilters,
      'ob': orderBy,
      'p': page,
    });
    return sha1.convert(utf8.encode(raw)).toString();
  }
}
