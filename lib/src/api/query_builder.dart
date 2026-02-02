// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'doctype_service.dart';

class QueryBuilder {
  final DoctypeService _service;
  final String doctype;

  final List<String> _fields = [];
  final List<List<dynamic>> _filters = [];
  int _limitStart = 0;
  int _limitPageLength = 20;
  String? _orderBy;

  QueryBuilder(this._service, this.doctype);

  QueryBuilder select(List<String> fields) {
    _fields.addAll(fields);
    return this;
  }

  QueryBuilder where(String field, dynamic operatorOrValue, [dynamic value]) {
    if (value == null) {
      _filters.add([doctype, field, '=', operatorOrValue]);
    } else {
      _filters.add([doctype, field, operatorOrValue, value]);
    }
    return this;
  }

  QueryBuilder filters(List<List<dynamic>> filters) {
    _filters.addAll(filters);
    return this;
  }

  QueryBuilder orderBy(String field, {bool descending = false}) {
    _orderBy = '$field ${descending ? 'desc' : 'asc'}';
    return this;
  }

  QueryBuilder limit(int pageLength, {int start = 0}) {
    _limitPageLength = pageLength;
    _limitStart = start;
    return this;
  }

  Future<List<dynamic>> get() async {
    return _service.list(
      doctype,
      fields: _fields.isEmpty ? ['*'] : _fields,
      filters: _filters,
      limitStart: _limitStart,
      limitPageLength: _limitPageLength,
      orderBy: _orderBy,
    );
  }

  Future<Map<String, dynamic>?> first() async {
    limit(1);
    final results = await get();
    if (results.isNotEmpty) {
      return results.first as Map<String, dynamic>;
    }
    return null;
  }
}
