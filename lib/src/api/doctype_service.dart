// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:convert';
import 'dart:math' as math;

import '../sync/sync_details.dart';
import '../utils/sdk_log.dart';
import 'exceptions.dart';
import 'rest_helper.dart';
import 'utils.dart';

class DoctypeService {
  final RestHelper _restHelper;
  final int listChildDocsPageSize;
  final int listFullDocsPageSize;
  final int listDefaultPageSize;

  /// Wired by [FrappeSDK] once [MetaService] exists. Expands a wildcard
  /// `fields: ['*']` into the doctype's concrete column fieldnames, because
  /// this server's `frappe.client.get_list` rejects `*` with
  /// "Field not permitted in query: *". Null before wiring / in tests.
  Future<List<String>> Function(String doctype)? starFieldsResolver;

  DoctypeService(
    this._restHelper, {
    this.listChildDocsPageSize = 1000,
    this.listFullDocsPageSize = 1000,
    this.listDefaultPageSize = 20,
  });

  Future<Map<String, dynamic>> getDocTypeMeta(String doctype) async {
    final response = await _restHelper.get(
      '/api/method/frappe.desk.form.load.getdoctype',
      queryParams: {'doctype': doctype},
    );

    if (response is Map<String, dynamic> && response.containsKey('docs')) {
      return response;
    }

    return response as Map<String, dynamic>;
  }

  /// Fetches just the `modified` timestamp of a DocType meta. Used by the
  /// offline-first watermark check (spec §4.9). Avoids the full meta payload.
  /// Returns null if the request fails or the DocType has no recorded
  /// modified timestamp on the server.
  Future<String?> getDocTypeWatermark(String doctype) async {
    try {
      final response = await _restHelper.get(
        '/api/method/frappe.client.get_value',
        queryParams: {
          'doctype': 'DocType',
          'filters': jsonEncode({'name': doctype}),
          'fieldname': jsonEncode(['modified']),
        },
      );
      if (response is Map<String, dynamic>) {
        final message = response['message'];
        if (message is Map && message['modified'] != null) {
          return message['modified'].toString();
        }
      }
      return null;
    } catch (e, st) {
      sdkLog('DoctypeService.getDocTypeWatermark($doctype) failed — $e\n$st');
      return null;
    }
  }

  Future<List<dynamic>> list(
    String doctype, {
    List<String>? fields,
    List<List<dynamic>>? filters,
    List<List<dynamic>>? orFilters,
    int limitStart = 0,
    int? limitPageLength,
    String? orderBy,
  }) async {
    final resolvedLimit = limitPageLength ?? listDefaultPageSize;
    final methodParams = <String, dynamic>{
      'doctype': doctype,
      'limit_start': limitStart,
      'limit_page_length': resolvedLimit,
    };

    // This server's `frappe.client.get_list` rejects the `*` wildcard
    // ("Field not permitted in query: *"). When the caller asked for '*',
    // expand it to the doctype's concrete column fieldnames via the wired
    // [starFieldsResolver]; fall back to the original fields on any failure.
    List<String>? effectiveFields = fields;
    final resolver = starFieldsResolver;
    if (fields != null && fields.contains('*') && resolver != null) {
      try {
        final expanded = await resolver(doctype);
        if (expanded.isNotEmpty) {
          effectiveFields = <String>{
            ...expanded,
            ...fields.where((f) => f != '*'),
          }.toList();
        }
      } catch (e, st) {
        sdkLog(
          'DoctypeService.list: star-field expansion failed for '
          '$doctype — $e\n$st',
        );
      }
    }
    if (effectiveFields != null) {
      // Never send a bare `*` the server is documented (three lines up) to
      // reject. If expansion was unavailable or failed, strip it and let the
      // remaining explicit fields stand; an empty result omits `fields`
      // entirely, which Frappe answers with its default field set rather than
      // an error. Keeping `*` guaranteed a failed request.
      if (effectiveFields.contains('*')) {
        effectiveFields = effectiveFields.where((f) => f != '*').toList();
      }
      if (effectiveFields.isNotEmpty) {
        methodParams['fields'] = jsonEncode(effectiveFields);
      }
    }
    if (filters != null) methodParams['filters'] = jsonEncode(filters);
    if (orFilters != null && orFilters.isNotEmpty) {
      methodParams['or_filters'] = jsonEncode(orFilters);
    }
    if (orderBy != null) methodParams['order_by'] = orderBy;

    final response = await _restHelper.get(
      '/api/method/frappe.client.get_list',
      queryParams: methodParams,
    );

    if (response is Map<String, dynamic> && response.containsKey('message')) {
      final msg = response['message'];
      if (msg is List) return msg;
      // Frappe returned a non-List message (null, error string, etc.).
      // Treat as empty page — callers see no records and pull continues.
      sdkLog(
        'DoctypeService.list: unexpected message shape for $doctype '
        '(${msg?.runtimeType ?? "null"}) — treating as empty page',
      );
      return [];
    }
    return [];
  }

  /// Counts records via `frappe.client.get_count`. Whitelisted in
  /// `apps/frappe/frappe/client.py:79`. Returns the total matching count,
  /// or 0 when the response is malformed. Optional [filters] follow the
  /// same `[field, operator, value]` shape as [list].
  Future<int> count(String doctype, {List<List<dynamic>>? filters}) async {
    final methodParams = <String, dynamic>{'doctype': doctype};
    if (filters != null && filters.isNotEmpty) {
      methodParams['filters'] = jsonEncode(filters);
    }
    final response = await _restHelper.get(
      '/api/method/frappe.client.get_count',
      queryParams: methodParams,
    );
    if (response is Map<String, dynamic>) {
      final message = response['message'];
      if (message is int) return message;
      if (message is num) return message.toInt();
      if (message is String) return int.tryParse(message) ?? 0;
    }
    return 0;
  }

  /// Lists child doctype records with ALL fields.
  /// get_list and reportview only return standard fields for child doctypes.
  /// This fetches names first, then batch-loads full docs via /api/resource.
  Future<List<Map<String, dynamic>>> listChildDocs(
    String doctype, {
    List<List<dynamic>>? filters,
    int? limitPageLength,
  }) async {
    final resolvedLimit = limitPageLength ?? listChildDocsPageSize;
    // Step 1: get names (get_list works for this)
    final nameList = await list(
      doctype,
      fields: ['name'],
      filters: filters,
      limitPageLength: resolvedLimit,
    );
    if (nameList.isEmpty) return [];

    // Step 2: batch-fetch full documents via /api/resource/{doctype}/{name}
    final docs = <Map<String, dynamic>>[];
    const batchSize = 50;
    for (var i = 0; i < nameList.length; i += batchSize) {
      final batch = nameList.skip(i).take(batchSize);
      final futures = batch.map((n) {
        final name = n is Map<String, dynamic>
            ? n['name']?.toString() ?? ''
            : '';
        if (name.isEmpty) return Future.value(<String, dynamic>{});
        return getByName(doctype, name);
      });
      final results = await Future.wait(futures);
      docs.addAll(results.where((d) => d.isNotEmpty));
    }
    return docs;
  }

  Future<Map<String, dynamic>> getByName(String doctype, String name) async {
    final response = await _restHelper.get('/api/resource/$doctype/$name');
    return unwrapData<Map<String, dynamic>>(response);
  }

  /// Bulk-fetch full parent docs (with embedded child rows) via the
  /// `mobile_sync.get_docs_with_children` server endpoint shipped in
  /// `mobile_control`. The server enforces the same per-doc permission
  /// gate as `/api/resource/<doctype>/<name>` (via
  /// `doc.check_permission("read")`), so denied / missing names are
  /// silently dropped — return length may be < input length.
  ///
  /// Must be kept in sync with `MAX_BATCH` on the server (200).
  Future<List<Map<String, dynamic>>> bulkGetWithChildren(
    String doctype,
    List<String> names,
  ) async {
    if (names.isEmpty) return [];
    final response = await _restHelper.post(
      '/api/method/mobile_sync.get_docs_with_children',
      body: {'doctype': doctype, 'names': names},
    );
    final dynamic message = response is Map<String, dynamic>
        ? response['message']
        : response;
    if (message is! List) {
      // MUST throw, never return []. An empty batch is how this endpoint
      // reports "every requested name was denied or deleted", and
      // [listFullDocsPage] turns that into `docs: []` with a non-zero
      // `namesScanned` plus a scanned-window watermark — which the INCREMENTAL
      // pull reads as "this window is genuinely unreadable, advance the
      // watermark past it" (see PullPageFetcher.fetch). Letting a malformed 2xx
      // reach that same `[]` would move the watermark past rows that are
      // READABLE and were never fetched: permanent silent data loss,
      // recoverable only by clearing the cursor.
      //
      // This is reachable, not theoretical. `RestHelper._handleResponse` hands
      // back the RAW BODY STRING for any 2xx whose `jsonDecode` fails, so a
      // truncated or proxy-mangled response on the largest payload the SDK ever
      // requests — up to 200 full documents plus their child rows — arrives
      // here as a String. Failing the page instead leaves the cursor untouched
      // and retries on the next cycle.
      //
      // Status 502 deliberately, NOT 404: the caller's `on ApiException` treats
      // 404 as "endpoint absent on this deployment" and degrades to per-name
      // GETs, which would mask a transient upstream failure as an N+1 success.
      throw ApiException(
        'mobile_sync.get_docs_with_children returned a 2xx body that is not '
        '{"message": [...]}; refusing to report an unreadable response as an '
        'empty batch, because the pull cannot distinguish that from '
        '"every name denied" and would advance the watermark past readable rows',
        502,
        message is String && message.length > 200
            ? '${message.substring(0, 200)}…'
            : message,
      );
    }
    return [
      for (final row in message)
        if (row is Map) Map<String, dynamic>.from(row),
    ];
  }

  /// Server-side per-request doctype cap (`mobile_control` `sync_details`
  /// `MAX_DOCTYPES`). A request listing more than this many doctypes is
  /// rejected with HTTP 417. Kept in sync with the server constant.
  static const int _syncDetailsMaxDoctypes = 100;

  /// Pre-flight manifest (#49). Posts the INCREMENTAL doctypes about to be
  /// pulled, each with its own `since` watermark, and returns per-doctype
  /// change info. Returns null on ANY failure (network, 404, missing endpoint,
  /// malformed body) so the caller falls back to a full pull.
  ///
  /// The server caps a single request at [_syncDetailsMaxDoctypes] doctypes
  /// (HTTP 417 above it). To stay transparent to EVERY SDK consumer, a request
  /// at or below the cap is sent as a SINGLE call — byte-for-byte the original
  /// behaviour, so no existing/legacy app is affected. Only a larger request is
  /// transparently split into cap-sized chunks and merged. If ANY chunk fails,
  /// the whole call returns null (the same all-or-nothing full-pull contract as
  /// before), so a partial manifest can never cause an incorrect skip.
  Future<SyncDetailsResponse?> getSyncDetails(
    List<Map<String, String>> doctypeSince,
  ) async {
    if (doctypeSince.isEmpty) return null;

    // Fast path: at/under the cap — identical to the pre-chunking behaviour.
    if (doctypeSince.length <= _syncDetailsMaxDoctypes) {
      return _postSyncDetailsChunk(doctypeSince);
    }

    // Over the cap: split into cap-sized chunks, post each, merge the results.
    final merged = <String, SyncDetailsEntry>{};
    var deleteSignals = 0;
    for (var i = 0; i < doctypeSince.length; i += _syncDetailsMaxDoctypes) {
      final end = (i + _syncDetailsMaxDoctypes < doctypeSince.length)
          ? i + _syncDetailsMaxDoctypes
          : doctypeSince.length;
      final res = await _postSyncDetailsChunk(doctypeSince.sublist(i, end));
      // Preserve the all-or-nothing contract: any failed chunk => full pull.
      if (res == null) return null;
      merged.addAll(res.entries);
      deleteSignals += res.deleteSignals;
    }
    return SyncDetailsResponse(entries: merged, deleteSignals: deleteSignals);
  }

  /// Single POST to `mobile_sync.sync_details` for [doctypeSince] (caller
  /// guarantees length <= [_syncDetailsMaxDoctypes]). Returns null on any
  /// failure — identical to the original [getSyncDetails] body.
  Future<SyncDetailsResponse?> _postSyncDetailsChunk(
    List<Map<String, String>> doctypeSince,
  ) async {
    try {
      final response = await _restHelper.post(
        '/api/method/mobile_sync.sync_details',
        body: {'doctypes': doctypeSince},
      );
      final dynamic message = response is Map<String, dynamic>
          ? response['message']
          : response;
      if (message is! Map) return null;
      return SyncDetailsResponse.fromJson(Map<String, dynamic>.from(message));
    } catch (e, st) {
      sdkLog(
        'DoctypeService.getSyncDetails failed — falling back to full pull — '
        '$e\n$st',
      );
      return null;
    }
  }

  /// Pages through `frappe.client.get_list` for names, then bulk-fetches
  /// full documents (parents + child rows) via the server-side
  /// `mobile_sync.get_docs_with_children` endpoint. Used by the pull
  /// engine for parents that declare child tables, since `get_list`
  /// returns flat parent rows only — child arrays are missing.
  ///
  /// Caller is responsible for paginating across the full result set; one
  /// call returns at most [limitPageLength] full docs starting at
  /// [limitStart].
  ///
  /// Returns docs only. Callers that page against a watermark should prefer
  /// [listFullDocsPage], which additionally reports how many names were
  /// scanned — without it, a page whose names are entirely dropped by the
  /// permission gate is indistinguishable from end-of-stream.
  Future<List<Map<String, dynamic>>> listFullDocs(
    String doctype, {
    List<List<dynamic>>? filters,
    int limitStart = 0,
    int? limitPageLength,
    String? orderBy,
  }) async => (await listFullDocsPage(
    doctype,
    filters: filters,
    limitStart: limitStart,
    limitPageLength: limitPageLength,
    orderBy: orderBy,
  )).docs;

  /// [listFullDocs] plus the number of candidate names the inner `get_list`
  /// returned for this window.
  ///
  /// Three guarantees the plain variant cannot express:
  ///
  /// 1. **Docs come back in `names` order** — i.e. in the [orderBy] the caller
  ///    asked for. [bulkGetWithChildren] is a `names in (...)` bulk fetch that
  ///    neither requests nor verifies server-side ordering, so accumulating its
  ///    batches in arrival order would silently violate the [orderBy] contract
  ///    the pull watermark depends on.
  /// 2. **`namesScanned` distinguishes "filtered" from "exhausted".** The
  ///    per-doc gate in [bulkGetWithChildren] drops denied/missing names, so
  ///    `docs.length < namesScanned` is normal and `docs.isEmpty` while
  ///    `namesScanned > 0` means *this page* was filtered out — not that the
  ///    doctype is drained.
  /// 3. **`scannedMaxModified`/`scannedMaxName` are the window's watermark,
  ///    not the returned docs'.** A caller paging with `limit_start` pinned at
  ///    0 needs a watermark that advances even when the page returns zero
  ///    docs; `null` means the listed rows carried no `modified` and the
  ///    caller must not advance.
  Future<
    ({
      List<Map<String, dynamic>> docs,
      int namesScanned,
      String? scannedMaxModified,
      String? scannedMaxName,
    })
  >
  listFullDocsPage(
    String doctype, {
    List<List<dynamic>>? filters,
    int limitStart = 0,
    int? limitPageLength,
    String? orderBy,
  }) async {
    final resolvedLimit = limitPageLength ?? listFullDocsPageSize;
    final nameList = await list(
      doctype,
      fields: ['name', 'modified'],
      filters: filters,
      limitStart: limitStart,
      limitPageLength: resolvedLimit,
      orderBy: orderBy,
    );
    if (nameList.isEmpty) {
      return (
        docs: const <Map<String, dynamic>>[],
        namesScanned: 0,
        scannedMaxModified: null,
        scannedMaxName: null,
      );
    }

    // Use `?.toString()` (matches listChildDocs) so int-valued `name`
    // fields from Frappe's autoname-by-numeric-series — which historically
    // dropped silently under the `is String` check — round-trip correctly.
    final names = <String>[
      for (final n in nameList)
        if (n is Map<String, dynamic>)
          if (n['name']?.toString() case final String s when s.isNotEmpty) s,
    ];
    if (names.isEmpty) {
      return (
        docs: const <Map<String, dynamic>>[],
        namesScanned: 0,
        scannedMaxModified: null,
        scannedMaxName: null,
      );
    }

    // High-water `(modified, name)` of the window that was SCANNED, independent
    // of which of those names survived the per-doc gate. The incremental pull
    // pins `limit_start` at 0, so a window whose every name is denied leaves it
    // no offset to step over — moving `modified` past the scanned window is the
    // only way forward. Deliberately a max rather than `nameList.last`: correct
    // even if the server ever stops honouring `order_by`, and it can never hand
    // back a value that moves a watermark backwards.
    //
    // Lexicographic compare is chronological here: Frappe timestamps are
    // fixed-width `YYYY-MM-DD HH:MM:SS[.ffffff]`. A row with no `modified` is
    // skipped, so a server that omits the column yields null — which the
    // fetcher treats as "cannot advance", i.e. today's behaviour exactly.
    String? scannedMaxModified;
    String? scannedMaxName;
    for (final r in nameList) {
      if (r is! Map<String, dynamic>) continue;
      final m = r['modified'] as String?;
      if (m == null) continue;
      final n = r['name']?.toString() ?? '';
      final cmp = scannedMaxModified == null
          ? 1
          : m.compareTo(scannedMaxModified);
      if (cmp > 0 || (cmp == 0 && n.compareTo(scannedMaxName ?? '') > 0)) {
        scannedMaxModified = m;
        scannedMaxName = n;
      }
    }

    // Must equal `MAX_BATCH` in the server's
    // `mobile_control/api/bulk_fetch.py` — exceeding it makes the endpoint
    // throw ValidationError for the whole chunk. This is an UNENFORCED
    // cross-repo invariant (no test on either side asserts they match), and the
    // server file carries the reciprocal note. Each chunk is a single HTTP
    // round-trip, so this typically reduces a 1000-row pull from ~1001 calls
    // (1 list + 1000 per-name GETs) down to ~6 calls.
    const int chunkSize = 200;
    final byName = <String, Map<String, dynamic>>{};
    for (var i = 0; i < names.length; i += chunkSize) {
      final chunk = names.sublist(i, math.min(i + chunkSize, names.length));
      List<Map<String, dynamic>> batch;
      try {
        batch = await bulkGetWithChildren(doctype, chunk);
      } on ApiException catch (e) {
        // Older deployments may not have `mobile_control` (or have a
        // version without `mobile_sync.get_docs_with_children`). Fall
        // back to per-name GETs only on 404 — let 5xx / auth / other
        // failures propagate so they aren't masked as silent N+1.
        if (e.statusCode != 404) rethrow;
        batch = await _perNameFallback(doctype, chunk);
      }
      for (final doc in batch) {
        final key = doc['name']?.toString();
        if (key != null && key.isNotEmpty) byName[key] = doc;
      }
    }

    // Emit in the requested `names` order rather than batch-arrival order.
    return (
      docs: <Map<String, dynamic>>[
        for (final n in names)
          if (byName[n] case final Map<String, dynamic> doc) doc,
      ],
      namesScanned: names.length,
      scannedMaxModified: scannedMaxModified,
      scannedMaxName: scannedMaxName,
    );
  }

  Future<List<Map<String, dynamic>>> _perNameFallback(
    String doctype,
    List<String> names,
  ) async {
    // Bounded concurrency: a 200-name chunk fanned out as 200 simultaneous
    // sockets can trip per-host limits and trigger a thundering-herd retry
    // storm against an already-strained server.
    const int sliceSize = 20;
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < names.length; i += sliceSize) {
      final slice = names.sublist(i, math.min(i + sliceSize, names.length));
      final results = await Future.wait(
        slice.map((n) => getByName(doctype, n)),
      );
      out.addAll(results.where((d) => d.isNotEmpty));
    }
    return out;
  }
}
