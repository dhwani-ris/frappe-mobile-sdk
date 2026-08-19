import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart';
import 'exceptions.dart';
import 'utils.dart';
import '../utils/api_tracer.dart';

/// Shared RNG for retry jitter. Not security-sensitive; a single instance
/// avoids re-seeding cost and gives independent draws across retries.
final Random _backoffRandom = Random();

/// Equal-jitter exponential backoff for HTTP GET retries (#42 / A3).
///
/// Returns a delay in `[base/2, base]` where `base = 500ms * 2^attempt`.
/// Keeping half the deterministic backoff guarantees a minimum spacing while
/// randomising the rest de-synchronises simultaneous client reconnects,
/// avoiding a thundering-herd against the Frappe backend after a shared outage.
///
/// [attempt] is clamped to `[0, 16]` so a runaway counter can never overflow
/// `1 << attempt` into a tiny or negative `Duration`. Pass a seeded [random]
/// in tests for determinism.
///
/// Note the ceiling: at `attempt == 16` the deterministic base is
/// `500 * 2^16 ≈ 32.8s * 1000 = ~9.1 hours`. In practice `RestHelper` calls
/// this with `attempt ∈ {0, 1}` (default budget of 2 retries), so the real
/// delay never exceeds ~1s. Callers that may pass larger attempts — or that
/// want a hard ceiling regardless — should pass [maxDelayMs] (e.g. `30000`),
/// which caps the deterministic base before jitter so the returned delay
/// stays in `[maxDelayMs/2, maxDelayMs]`. Left null (the default), behaviour
/// is unchanged.
Duration retryBackoffDelay(int attempt, {Random? random, int? maxDelayMs}) {
  assert(attempt >= 0, 'retry attempt must be non-negative');
  assert(
    maxDelayMs == null || maxDelayMs > 0,
    'maxDelayMs must be positive when provided',
  );
  final n = attempt.clamp(0, 16);
  var base = 500 * (1 << n);
  if (maxDelayMs != null && base > maxDelayMs) base = maxDelayMs;
  final half = base ~/ 2;
  final rnd = random ?? _backoffRandom;
  return Duration(milliseconds: half + rnd.nextInt(half + 1));
}

/// HTTP client for Frappe REST API.
///
/// Supports session cookie, API key, and Bearer token auth.
/// [onTokenExpired] is invoked on 401 when using Bearer token; return true to retry.
class RestHelper {
  final String baseUrl;
  final http.Client _client;
  final Future<bool> Function()? onTokenExpired;

  /// Per-request hard ceiling. Without this, a server that accepts the TCP
  /// connection but never sends a response would hang the caller forever
  /// (Dart's http.Client has no default timeout). Boot-time SDK init awaits
  /// these calls, so a hang freezes the splash spinner.
  final Duration requestTimeout;

  /// Longer ceiling for multipart uploads where slow uplinks are normal.
  final Duration uploadTimeout;

  String? _sidCookie;
  String? _apiKey;
  String? _apiSecret;
  String? _bearerToken;

  http.Client get client => _client;

  RestHelper(
    String baseUrlParam, {
    http.Client? client,
    this.onTokenExpired,
    this.requestTimeout = const Duration(seconds: 30),
    this.uploadTimeout = const Duration(minutes: 5),
  }) : baseUrl = baseUrlParam.endsWith('/')
           ? baseUrlParam.substring(0, baseUrlParam.length - 1)
           : baseUrlParam,
       _client = client ?? http.Client();

  /// Sets session cookie for credential-based auth.
  void setSessionCookie(String sid) {
    _sidCookie = sid;
  }

  /// Sets API key and secret for token-based auth.
  void setApiKey(String key, String secret) {
    _apiKey = key;
    _apiSecret = secret;
  }

  /// Sets Bearer token for OAuth auth.
  void setBearerToken(String? token) {
    _bearerToken = token;
  }

  /// Clears all auth state.
  void clearSession() {
    _sidCookie = null;
    _apiKey = null;
    _apiSecret = null;
    _bearerToken = null;
  }

  Map<String, String> _getHeaders({bool includeAuth = true}) {
    final headers = <String, String>{'Accept': 'application/json'};

    if (!includeAuth) {
      return headers;
    }

    if (_bearerToken != null) {
      headers['Authorization'] = 'Bearer $_bearerToken';
    } else if (_sidCookie != null) {
      headers['Cookie'] =
          'sid=$_sidCookie; system_user=yes; full_name=Guest; user_id=Guest; user_image=';
    } else if (_apiKey != null && _apiSecret != null) {
      headers['Authorization'] = 'token $_apiKey:$_apiSecret';
    }

    return headers;
  }

  /// Auth headers for use with Image.network etc. when loading private files.
  Map<String, String> get requestHeaders =>
      Map<String, String>.from(_getHeaders());

  /// Performs a GET request.
  ///
  /// [timeout] overrides [requestTimeout] for this single call — use a
  /// short value (e.g. 10s) for splash-blocking calls where the default
  /// 30s × 3-retry budget (~93s worst case) would freeze the UI.
  /// [maxRetries] overrides the default GET retry budget (2 retries on
  /// transient network errors). Pass `0` for fast-fail boot probes.
  Future<dynamic> get(
    String endpoint, {
    Map<String, dynamic>? queryParams,
    Duration? timeout,
    int? maxRetries,
  }) async {
    return _request(
      'GET',
      endpoint,
      queryParams: queryParams,
      timeout: timeout,
      maxRetries: maxRetries,
    );
  }

  /// Performs a GET request without auth headers.
  Future<dynamic> getPublic(
    String endpoint, {
    Map<String, dynamic>? queryParams,
    Duration? timeout,
    int? maxRetries,
  }) async {
    return _request(
      'GET',
      endpoint,
      queryParams: queryParams,
      includeAuth: false,
      timeout: timeout,
      maxRetries: maxRetries,
    );
  }

  /// Performs a POST request.
  Future<dynamic> post(String endpoint, {dynamic body}) async {
    return _request('POST', endpoint, body: body);
  }

  /// Performs a POST request without auth headers.
  Future<dynamic> postPublic(String endpoint, {dynamic body}) async {
    return _request('POST', endpoint, body: body, includeAuth: false);
  }

  /// Performs a PUT request.
  Future<dynamic> put(String endpoint, {dynamic body}) async {
    return _request('PUT', endpoint, body: body);
  }

  /// Performs a DELETE request.
  Future<dynamic> delete(String endpoint) async {
    return _request('DELETE', endpoint);
  }

  Future<dynamic> _request(
    String method,
    String endpoint, {
    Map<String, dynamic>? queryParams,
    dynamic body,
    bool includeAuth = true,
    Duration? timeout,
    int? maxRetries,
  }) async {
    var uri = Uri.parse('$baseUrl$endpoint');
    if (queryParams != null) {
      uri = uri.replace(
        queryParameters: queryParams.map((k, v) => MapEntry(k, v.toString())),
      );
    }

    ApiTracer.traceRequest(
      method: method,
      url: uri.toString(),
      queryParams: method == 'GET' ? queryParams : null,
      body: method != 'GET' ? body : null,
    );

    final effectiveTimeout = timeout ?? requestTimeout;
    // Default budget: 1 initial attempt + 2 retries = 3 total attempts.
    // Pass `maxRetries: 0` from boot/probe call sites to fail fast.
    final effectiveMaxAttempts = (maxRetries ?? 2) + 1;

    int attempts = 0;
    while (attempts < effectiveMaxAttempts) {
      try {
        final headers = _getHeaders(includeAuth: includeAuth);
        if (method != 'GET' && body != null) {
          headers['Content-Type'] = 'application/json';
        }

        http.Response response;
        switch (method) {
          case 'GET':
            response = await _client
                .get(uri, headers: headers)
                .timeout(effectiveTimeout);
            break;
          case 'POST':
            response = await _client
                .post(
                  uri,
                  headers: headers,
                  body: body != null ? jsonEncode(body) : null,
                )
                .timeout(effectiveTimeout);
            break;
          case 'PUT':
            response = await _client
                .put(
                  uri,
                  headers: headers,
                  body: body != null ? jsonEncode(body) : null,
                )
                .timeout(effectiveTimeout);
            break;
          case 'DELETE':
            response = await _client
                .delete(uri, headers: headers)
                .timeout(effectiveTimeout);
            break;
          default:
            throw ApiException('Unsupported HTTP method: $method');
        }

        ApiTracer.traceResponse(
          statusCode: response.statusCode,
          url: uri.toString(),
          body: response.statusCode >= 400 ? response.body : null,
          error: null,
        );

        return await _handleResponse(
          response,
          requestUrl: uri.toString(),
          requestMethod: method,
          requestBody: method != 'GET' ? body : null,
        );
      } on AuthException catch (e) {
        // `includeAuth` is load-bearing, not a tidy-up. Without it the refresh
        // endpoint re-enters its own refresh: AuthService sends
        // `mobile_auth.refresh_token` via callPublic -> postPublic -> this same
        // `_request`, and deliberately leaves the Bearer set (nulling it would
        // race concurrent requests down to Guest -> 403). So a 401 from the
        // refresh call itself used to satisfy every condition below, re-invoke
        // `onTokenExpired`, and — since that callback is single-flighted —
        // `await` the very future it was already executing inside. Dart does
        // not detect await-on-self: it hangs silently and `_refreshInFlight` is
        // never nulled, wedging the session for the process lifetime (worst
        // case, on the boot-time restoreSession refresh, hanging the splash).
        //
        // Gating here is also correct on its own terms: a request that carries
        // no Authorization header cannot be repaired by refreshing a token, and
        // firing a real refresh for an `allow_guest` endpoint's 401 could get
        // that refresh rejected and wipe a logged-in user's stored tokens.
        if (includeAuth &&
            e.statusCode == 401 &&
            _bearerToken != null &&
            onTokenExpired != null) {
          final refreshed = await onTokenExpired!();
          if (refreshed) {
            attempts++;
            continue;
          }
        }
        rethrow;
      } on SocketException catch (e) {
        if (method == 'GET' && attempts < effectiveMaxAttempts - 1) {
          attempts++;
          await Future.delayed(retryBackoffDelay(attempts));
          continue;
        }
        final msg = e.message.toLowerCase();
        if (msg.contains('refused') || msg.contains('unreachable')) {
          throw NetworkException(
            'Cannot reach server. Check your Wi-Fi connection.',
          );
        }
        throw NetworkException('No internet connection');
      } on TimeoutException {
        if (method == 'GET' && attempts < effectiveMaxAttempts - 1) {
          attempts++;
          await Future.delayed(retryBackoffDelay(attempts));
          continue;
        }
        throw NetworkException(
          'Server is not responding. Check your connection or try again.',
        );
      } catch (e) {
        if (e is FrappeException) rethrow;
        throw NetworkException('Request failed: $e');
      }
    }
  }

  Future<dynamic> _handleResponse(
    http.Response response, {
    String? requestUrl,
    String? requestMethod,
    Object? requestBody,
  }) async {
    // Stamps wire-capture context onto a FrappeException before it is thrown,
    // so the push-side error-log collector can rebuild the exact request.
    Never throwStamped(FrappeException e) {
      e
        ..requestUrl = requestUrl
        ..requestMethod = requestMethod
        ..requestBody = requestBody
        ..responseBodyRaw = response.body
        // http lowercases header names; Frappe sets this only when server
        // monitoring is enabled, so it is best-effort and may be null.
        ..traceId = response.headers['x-frappe-request-id'];
      throw e;
    }

    dynamic body;
    try {
      body = await compute(jsonDecode, response.body);
    } catch (e, st) {
      // Non-JSON body. On 2xx we return raw text; on error status we
      // synthesize an ApiException below using the same raw body. Logged
      // because a missing JSON envelope on an error response is often
      // useful when triaging server-side issues.
      debugPrint(
        'RestHelper._handleResponse: jsonDecode failed (status=${response.statusCode}) — $e\n$st',
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response.body;
      }
      throwStamped(
        ApiException(
          toUserFriendlyMessage(response.body),
          response.statusCode,
          response.body,
        ),
      );
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return body;
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throwStamped(
        AuthException(
          toUserFriendlyMessage(extractErrorMessage(body)),
          response.statusCode,
        ),
      );
    }

    if (response.statusCode == 417) {
      throwStamped(
        ValidationException(
          toUserFriendlyMessage(extractErrorMessage(body)),
          body is Map<String, dynamic> ? body : null,
        ),
      );
    }

    if (response.statusCode == 404) {
      throwStamped(
        ApiException(
          toUserFriendlyMessage(extractErrorMessage(body)),
          404,
          body,
        ),
      );
    }

    throwStamped(
      ApiException(
        toUserFriendlyMessage(extractErrorMessage(body)),
        response.statusCode,
        body,
      ),
    );
  }

  /// Calls a Frappe API method (e.g. frappe.client.get_list).
  Future<dynamic> call(
    String method, {
    Map<String, dynamic>? args,
    String httpMethod = 'POST',
  }) async {
    final endpoint = '/api/method/$method';
    if (httpMethod.toUpperCase() == 'GET') {
      return get(endpoint, queryParams: args);
    } else {
      return post(endpoint, body: args);
    }
  }

  /// Calls a Frappe API method without auth headers.
  Future<dynamic> callPublic(
    String method, {
    Map<String, dynamic>? args,
    String httpMethod = 'POST',
  }) async {
    final endpoint = '/api/method/$method';
    if (httpMethod.toUpperCase() == 'GET') {
      return getPublic(endpoint, queryParams: args);
    } else {
      return postPublic(endpoint, body: args);
    }
  }

  /// Uploads a file via multipart/form-data.
  Future<dynamic> uploadFile(
    String endpoint,
    String fieldName,
    File file, {
    Map<String, String>? fields,
    String? filename,
  }) async {
    var uri = Uri.parse('$baseUrl$endpoint');
    var request = http.MultipartRequest('POST', uri);

    request.headers.addAll(_getHeaders());

    if (fields != null) {
      request.fields.addAll(fields);
    }

    var stream = http.ByteStream(file.openRead());
    var length = await file.length();

    var multipartFile = http.MultipartFile(
      fieldName,
      stream,
      length,
      // Falls back to the on-disk basename, which for a staged attachment IS
      // the name the user picked: `MediaStore.stageToOutbox` keeps the original
      // filename and puts uniqueness in the generated parent directory. (It
      // once renamed to `<uuid><ext>`, which lost the name permanently and made
      // every upload land server-side as an opaque uuid.)
      filename: filename ?? basename(file.path),
    );

    request.files.add(multipartFile);

    try {
      var streamedResponse = await _client.send(request).timeout(uploadTimeout);
      var response = await http.Response.fromStream(
        streamedResponse,
      ).timeout(uploadTimeout);
      return await _handleResponse(
        response,
        requestUrl: uri.toString(),
        requestMethod: 'POST',
        requestBody: fields,
      );
    } on TimeoutException {
      throw NetworkException(
        'Upload timed out. Check your connection and try again.',
      );
    } catch (e) {
      if (e is FrappeException) rethrow;
      throw NetworkException('Upload failed: $e');
    }
  }
}
