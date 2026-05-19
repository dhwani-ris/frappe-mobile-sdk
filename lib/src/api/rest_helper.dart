import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart';
import 'exceptions.dart';
import 'utils.dart';
import '../utils/api_tracer.dart';

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

        return _handleResponse(response);
      } on AuthException catch (e) {
        if (e.statusCode == 401 &&
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
          await Future.delayed(Duration(milliseconds: 500 * (1 << attempts)));
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
          await Future.delayed(Duration(milliseconds: 500 * (1 << attempts)));
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

  dynamic _handleResponse(http.Response response) {
    dynamic body;
    try {
      body = jsonDecode(response.body);
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
      throw ApiException(
        toUserFriendlyMessage(response.body),
        response.statusCode,
        response.body,
      );
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return body;
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw AuthException(
        toUserFriendlyMessage(extractErrorMessage(body)),
        response.statusCode,
      );
    }

    if (response.statusCode == 417) {
      throw ValidationException(
        toUserFriendlyMessage(extractErrorMessage(body)),
        body is Map<String, dynamic> ? body : null,
      );
    }

    if (response.statusCode == 404) {
      throw ApiException(toUserFriendlyMessage(extractErrorMessage(body)), 404);
    }

    throw ApiException(
      toUserFriendlyMessage(extractErrorMessage(body)),
      response.statusCode,
      body,
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
      filename: basename(file.path),
    );

    request.files.add(multipartFile);

    try {
      var streamedResponse = await _client.send(request).timeout(uploadTimeout);
      var response = await http.Response.fromStream(
        streamedResponse,
      ).timeout(uploadTimeout);
      return _handleResponse(response);
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
