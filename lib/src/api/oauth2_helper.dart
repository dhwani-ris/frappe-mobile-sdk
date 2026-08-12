import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'exceptions.dart';

/// Builds a Frappe `api/method/<path>` URI from [baseUrl], normalising
/// the trailing slash so `baseUrl` with or without a trailing `/`
/// produces the same URI. Single source of truth for OAuth endpoint URL
/// construction.
Uri _oauthUri(String baseUrl, String path) {
  final root = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
  return Uri.parse('${root}api/method/$path');
}

/// Performs a form-encoded `application/x-www-form-urlencoded` POST to
/// [uri], throws `ApiException('$errorLabel failed: <status>', <status>)` on
/// non-200, and returns the decoded JSON map. Shared by
/// [OAuth2Helper.exchangeCodeForToken] and [OAuth2Helper.refreshToken] which
/// previously had byte-for-byte identical http.post calls.
///
/// The thrown exception CARRIES THE STATUS CODE — callers classify a dead
/// credential (401/403/417) apart from a transport or server-side blip on it.
Future<Map<String, dynamic>> _postFormEncoded(
  Uri uri,
  Map<String, String> body,
  String errorLabel,
) async {
  final response = await http.post(
    uri,
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Accept': 'application/json',
    },
    body: body.keys.map((k) => '$k=${Uri.encodeComponent(body[k]!)}').join('&'),
  );
  if (response.statusCode != 200) {
    // Do NOT embed response.body: OAuth error bodies can carry tokens,
    // client_secret echoes, or error_description PII that would then leak into
    // crash reporters and log aggregators via the exception's stack trace.
    // `details` is left null for the same reason.
    //
    // [ApiException], not a bare `Exception`, SPECIFICALLY so the status
    // survives. `AuthService` classifies a refresh failure with
    // `isDefinitiveRefreshRejection`, which matches on [FrappeException] +
    // status; a bare exception carried the status only inside its MESSAGE, so
    // every OAuth failure — a genuinely dead grant and a dropped socket alike
    // — classified identically. That is what made the OAuth leg wipe tokens
    // while offline and never report the session as expired. ApiException
    // implements Exception, so existing `catch (e)` / `on Exception` handlers
    // are unaffected and the message text is unchanged.
    throw ApiException(
      '$errorLabel failed: ${response.statusCode}',
      response.statusCode,
    );
  }
  return jsonDecode(response.body) as Map<String, dynamic>;
}

/// PKCE code verifier and challenge pair (RFC 7636).
class PkcePair {
  final String codeVerifier;
  final String codeChallenge;

  PkcePair({required this.codeVerifier, required this.codeChallenge});
}

/// OAuth 2.0 token response from Frappe.
class OAuth2TokenResponse {
  final String accessToken;
  final String? refreshToken;
  final int? expiresIn;
  final String? tokenType;
  final String? scope;

  OAuth2TokenResponse({
    required this.accessToken,
    this.refreshToken,
    this.expiresIn,
    this.tokenType,
    this.scope,
  });

  factory OAuth2TokenResponse.fromJson(Map<String, dynamic> json) {
    return OAuth2TokenResponse(
      accessToken: json['access_token'] as String? ?? '',
      refreshToken: json['refresh_token'] as String?,
      expiresIn: json['expires_in'] as int?,
      tokenType: json['token_type'] as String?,
      scope: json['scope'] as String?,
    );
  }
}

/// Frappe OAuth 2.0 helper (authorization code + PKCE).
class OAuth2Helper {
  static Map<String, dynamic> _unwrapFrappeResponse(Map<String, dynamic> json) {
    if (json.containsKey('access_token')) return json;
    final msg = json['message'];
    if (msg is Map<String, dynamic> && msg.containsKey('access_token')) {
      return msg;
    }
    final data = json['data'];
    if (data is Map<String, dynamic> && data.containsKey('access_token')) {
      return data;
    }
    return json;
  }

  static const String _chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  /// Generates a PKCE pair (43–128 char verifier, S256 challenge).
  static PkcePair generatePkce() {
    final random = Random.secure();
    final verifier = List.generate(
      64,
      (_) => _chars[random.nextInt(_chars.length)],
    ).join();
    final verifierBytes = utf8.encode(verifier);
    final digest = sha256.convert(verifierBytes);
    final challenge = base64Url.encode(digest.bytes).replaceAll('=', '');
    return PkcePair(codeVerifier: verifier, codeChallenge: challenge);
  }

  /// Builds the OAuth authorize URL for user consent.
  static String getAuthorizeUrl({
    required String baseUrl,
    required String clientId,
    required String redirectUri,
    required String scope,
    required String state,
    String? codeChallenge,
    String codeChallengeMethod = 'S256',
    String responseType = 'code',
  }) {
    final uri = _oauthUri(baseUrl, 'frappe.integrations.oauth2.authorize');
    final q = <String, String>{
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'response_type': responseType,
      'scope': scope,
      'state': state,
    };
    if (codeChallenge != null && codeChallenge.isNotEmpty) {
      q['code_challenge'] = codeChallenge;
      q['code_challenge_method'] = codeChallengeMethod;
    }
    return uri.replace(queryParameters: q).toString();
  }

  /// Exchanges authorization code for access and refresh tokens.
  ///
  /// [codeVerifier] must match the PKCE verifier used in the authorize request.
  /// [clientSecret] is required for confidential OAuth clients.
  static Future<OAuth2TokenResponse> exchangeCodeForToken({
    required String baseUrl,
    required String clientId,
    required String redirectUri,
    required String code,
    String? codeVerifier,
    String? clientSecret,
  }) async {
    final uri = _oauthUri(baseUrl, 'frappe.integrations.oauth2.get_token');
    final body = <String, String>{
      'grant_type': 'authorization_code',
      'code': code,
      'client_id': clientId,
      'redirect_uri': redirectUri,
    };
    if (codeVerifier != null && codeVerifier.isNotEmpty) {
      body['code_verifier'] = codeVerifier;
    }
    if (clientSecret != null && clientSecret.isNotEmpty) {
      body['client_secret'] = clientSecret;
    }
    final json = await _postFormEncoded(uri, body, 'OAuth token exchange');
    if (json['error'] != null) {
      throw Exception(
        'OAuth error: ${json['error']} - ${json['error_description'] ?? ''}',
      );
    }
    final tokenJson = _unwrapFrappeResponse(json);
    return OAuth2TokenResponse.fromJson(tokenJson);
  }

  /// Refreshes the access token using [refreshToken].
  ///
  /// [clientSecret] is required for confidential OAuth clients.
  ///
  /// THROWS rather than returning a response that is not a usable token. A
  /// return from this method means "there is a live access token"; every other
  /// outcome is an exception the caller classifies. See the two guards below.
  static Future<OAuth2TokenResponse> refreshToken({
    required String baseUrl,
    required String clientId,
    required String refreshToken,
    String? clientSecret,
  }) async {
    final uri = _oauthUri(baseUrl, 'frappe.integrations.oauth2.get_token');
    final body = <String, String>{
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientId,
    };
    if (clientSecret != null && clientSecret.isNotEmpty) {
      body['client_secret'] = clientSecret;
    }
    final json = await _postFormEncoded(uri, body, 'OAuth refresh');
    // An RFC 6749 §5.2 error object. [exchangeCodeForToken] hits the SAME
    // endpoint and has always checked for this on a 200, so the shape occurs;
    // this leg never did, and `fromJson` happily produced an empty token from it.
    //
    // ONLY the `error` CODE travels into the exception. It is an RFC 6749 enum
    // (`invalid_grant`, `invalid_client`, …), so it carries no PII and does not
    // reopen the body-leak reason the rest of the body — `error_description`
    // included — stays out (see [_postFormEncoded]). `AuthService`
    // classifies on it via `isDefinitiveOAuthRejection`.
    final error = json['error'];
    if (error != null) {
      throw ApiException(
        'OAuth refresh rejected: $error',
        null,
        error.toString(),
      );
    }
    final parsed = OAuth2TokenResponse.fromJson(_unwrapFrappeResponse(json));
    // `OAuth2TokenResponse.fromJson` defaults a missing `access_token` to ''.
    // Returning that made the caller store an empty token, call
    // `setBearerToken('')` and report SUCCESS — after which
    // `_doRefreshMobileAuthToken` ran `markSessionRecovered()`, clearing the
    // dead-session latch and publishing `healthy` for a session that now 401s
    // on every request. The mobile leg has always had this guard
    // (`newAccessToken != null && newAccessToken.isNotEmpty`); this is its
    // OAuth-leg equivalent, and it lives HERE so both callers get it — the
    // reactive `_tryRefreshOAuthToken` and the launch-time `restoreSession`
    // leg, which had the same hole.
    //
    // No status: a 200 that is not a token response says nothing about the
    // grant, so callers must keep the tokens and arm a cooldown rather than
    // treat it as a rejection.
    if (parsed.accessToken.isEmpty) {
      throw ApiException('OAuth refresh returned no access_token');
    }
    return parsed;
  }

  /// Verifies [accessToken] by calling the OpenID userinfo endpoint.
  static Future<Map<String, dynamic>> verifyToken({
    required String baseUrl,
    required String accessToken,
  }) async {
    final uri = _oauthUri(baseUrl, 'frappe.integrations.oauth2.openid_profile');
    final response = await http.get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (response.statusCode != 200) {
      // See [_postFormEncoded]: the userinfo body can contain profile PII —
      // keep it out of the thrown exception (and therefore out of crash logs).
      throw Exception('Token verification failed: ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Revokes an access or refresh token.
  static Future<void> revokeToken({
    required String baseUrl,
    required String token,
  }) async {
    final uri = _oauthUri(baseUrl, 'frappe.integrations.oauth2.revoke_token');
    await http.post(
      uri,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: 'token=${Uri.encodeComponent(token)}',
    );
  }
}
