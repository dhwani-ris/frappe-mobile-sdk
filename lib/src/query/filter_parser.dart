import '../database/field_type_mapping.dart';
import '../database/normalize_for_search.dart';
import '../models/doc_type_meta.dart';
import 'filter_errors.dart';
import 'frappe_timespan.dart';
import 'parsed_query.dart';

/// Translates Frappe-style filter lists into a parameter-bound SQLite
/// `SELECT` against the local `docs__<doctype>` table. Spec §6.4.
///
/// **Pure** — no DB, no I/O. The `tableName` is whitelisted by caller
/// (typically [DoctypeMetaDao.getTableName]); columns are whitelisted
/// against `meta.fields` + a fixed system-column allowlist; values are
/// always passed through `params`, never string-concatenated.
///
/// Filter shapes accepted:
/// - `[col, op, value]` — the only supported triple.
/// - `[doctype, col, op, value]` — cross-doctype child filter; rejected
///   with [UnsupportedFilterError] so the caller knows to flatten.
class FilterParser {
  static const _allowedOps = <String>{
    '=', '!=', '<', '<=', '>', '>=',
    'in', 'not in',
    'like', 'not like',
    'between',
    'is', 'is not',
    'timespan',
  };

  /// System columns present on every `docs__<doctype>` table — see
  /// `parent_schema.dart`. Filterable by the caller even though they
  /// aren't part of `meta.fields`.
  static const Map<String, String> _systemColumns = {
    'mobile_uuid': 'TEXT',
    'server_name': 'TEXT',
    'sync_status': 'TEXT',
    'sync_error': 'TEXT',
    'sync_attempts': 'INTEGER',
    'modified': 'TEXT',
    'local_modified': 'INTEGER',
    'pulled_at': 'INTEGER',
    'docstatus': 'INTEGER',
  };

  static ParsedQuery toSql({
    required DocTypeMeta meta,
    required String tableName,
    required List<List> filters,
    List<List> orFilters = const [],
    String? orderBy,
    int page = 0,
    int pageSize = 50,
  }) {
    final colTypes = _columnTypes(meta);
    final normFields = _normFieldNames(meta);
    final whereParts = <String>[];
    final params = <Object?>[];

    for (final f in filters) {
      if (f.length == 4) {
        throw const UnsupportedFilterError(
          'Cross-doctype child-table filters '
          '[["Doctype","field","op","value"]] are not supported in v1; '
          'flatten to parent-field filters.',
        );
      }
      if (f.length != 3) {
        throw FilterParseError(
          'Malformed filter: $f (expected [col, op, value])',
        );
      }
      final parsed = _parseOne(f, colTypes, normFields);
      whereParts.add(parsed.sql);
      params.addAll(parsed.params);
    }

    final orParts = <String>[];
    for (final f in orFilters) {
      if (f.length == 4) {
        throw const UnsupportedFilterError(
          'Cross-doctype child-table or_filters not supported in v1.',
        );
      }
      if (f.length != 3) {
        throw FilterParseError('Malformed or_filter: $f');
      }
      final parsed = _parseOne(f, colTypes, normFields);
      orParts.add(parsed.sql);
      params.addAll(parsed.params);
    }

    final where = <String>[];
    where.addAll(whereParts);
    if (orParts.isNotEmpty) {
      where.add('(${orParts.join(' OR ')})');
    }

    final sb = StringBuffer('SELECT * FROM $tableName');
    if (where.isNotEmpty) {
      sb
        ..write(' WHERE ')
        ..write(where.join(' AND '));
    }
    if (orderBy != null && orderBy.isNotEmpty) {
      sb
        ..write(' ORDER BY ')
        ..write(_validateOrderBy(orderBy, colTypes));
    }
    sb
      ..write(' LIMIT ')
      ..write(pageSize)
      ..write(' OFFSET ')
      ..write(page * pageSize);
    return ParsedQuery(sql: sb.toString(), params: params);
  }

  static ParsedQuery _parseOne(
    List f,
    Map<String, String> colTypes,
    Set<String> normFields,
  ) {
    final col = f[0] as String;
    final op = (f[1] as String).toLowerCase().trim();
    final value = f[2];

    if (!colTypes.containsKey(col)) {
      throw FilterParseError('Unknown column: $col');
    }
    if (!_allowedOps.contains(op)) {
      throw FilterParseError('Unsupported operator: $op');
    }

    final type = colTypes[col]!;
    final isNumeric = type == 'INTEGER' || type == 'REAL';

    switch (op) {
      case '=':
      case '!=':
        if (isNumeric) {
          return ParsedQuery(
            sql: 'IFNULL($col, 0) $op ?',
            params: [value],
          );
        }
        return ParsedQuery(
          sql: "IFNULL($col, '') $op ?",
          params: [value],
        );
      case '<':
      case '<=':
      case '>':
      case '>=':
        return ParsedQuery(sql: '$col $op ?', params: [value]);
      case 'in':
      case 'not in':
        if (value is! List) {
          throw FilterParseError('"$op" requires a list value');
        }
        if (value.isEmpty) {
          return ParsedQuery(
            sql: op == 'in' ? '1=0' : '1=1',
            params: const [],
          );
        }
        final placeholders = List.filled(value.length, '?').join(', ');
        final sqlOp = op == 'in' ? 'IN' : 'NOT IN';
        return ParsedQuery(
          sql: '$col $sqlOp ($placeholders)',
          params: value.cast<Object?>(),
        );
      case 'like':
      case 'not like':
        final sqlOp = op == 'like' ? 'LIKE' : 'NOT LIKE';
        if (normFields.contains(col)) {
          return ParsedQuery(
            sql: "IFNULL(${col}__norm, '') $sqlOp ?",
            params: [normalizeForSearch(value?.toString())],
          );
        }
        return ParsedQuery(
          sql: "IFNULL($col, '') $sqlOp ?",
          params: [value],
        );
      case 'between':
        if (value is! List || value.length != 2) {
          throw const FilterParseError('"between" needs a 2-element list');
        }
        final start =
            _normalizeBetweenBound(value[0], isStart: true, type: type);
        final end =
            _normalizeBetweenBound(value[1], isStart: false, type: type);
        return ParsedQuery(
          sql: '$col >= ? AND $col <= ?',
          params: [start, end],
        );
      case 'timespan':
        if (value == null) {
          throw const FilterParseError('"timespan" requires a keyword value');
        }
        final range = FrappeTimespan.resolve(value.toString());
        return ParsedQuery(
          sql: '$col >= ? AND $col <= ?',
          params: [range.start, range.end],
        );
      case 'is':
        if (value == 'set') {
          return ParsedQuery(
            sql: "IFNULL($col, '') != ''",
            params: const [],
          );
        }
        if (value == 'not set') {
          return ParsedQuery(
            sql: "IFNULL($col, '') = ''",
            params: const [],
          );
        }
        if (value == null) {
          return ParsedQuery(sql: '$col IS NULL', params: const []);
        }
        throw FilterParseError(
          'Unsupported "is" value: $value '
          '(expected "set", "not set", or null)',
        );
      case 'is not':
        if (value == null) {
          return ParsedQuery(sql: '$col IS NOT NULL', params: const []);
        }
        throw FilterParseError(
          'Unsupported "is not" value: $value (expected null)',
        );
      default:
        throw FilterParseError('Unsupported operator: $op');
    }
  }

  /// Whitelist of legal column names → SQLite affinity. Built from
  /// `meta.fields` + system columns. Anything not in this map is
  /// rejected with [FilterParseError].
  static Map<String, String> _columnTypes(DocTypeMeta meta) {
    final map = <String, String>{};
    map.addAll(_systemColumns);
    for (final f in meta.fields) {
      final n = f.fieldname;
      if (n == null || n.isEmpty) continue;
      final sqlType = sqliteColumnTypeFor(f.fieldtype);
      if (sqlType == null) continue;
      map[n] = sqlType;
    }
    return map;
  }

  static Set<String> _normFieldNames(DocTypeMeta meta) {
    final s = <String>{};
    if (meta.titleField != null) s.add(meta.titleField!);
    for (final sf in (meta.searchFields ?? const <String>[])) {
      s.add(sf);
    }
    return s;
  }

  static String _validateOrderBy(String orderBy, Map<String, String> colTypes) {
    final parts = orderBy.trim().split(RegExp(r'\s+'));
    final col = parts[0];
    if (!colTypes.containsKey(col)) {
      throw FilterParseError('Unknown ORDER BY column: $col');
    }
    final dir = parts.length > 1 ? parts[1].toUpperCase() : 'ASC';
    if (dir != 'ASC' && dir != 'DESC') {
      throw FilterParseError('ORDER BY direction must be ASC or DESC: $dir');
    }
    return '$col $dir';
  }

  static Object? _normalizeBetweenBound(
    Object? v, {
    required bool isStart,
    required String type,
  }) {
    if (type != 'TEXT') return v;
    if (v is! String) return v;
    final hasTime = v.contains(':');
    if (hasTime) return v;
    return isStart ? '$v 00:00:00' : '$v 23:59:59';
  }
}
