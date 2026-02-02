import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

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
    final path = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final uri = Uri.parse(
      '${path}api/method/frappe.integrations.oauth2.authorize',
    );
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
    final path = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final uri = Uri.parse(
      '${path}api/method/frappe.integrations.oauth2.get_token',
    );
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
    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Accept': 'application/json',
      },
      body: body.keys
          .map((k) => '$k=${Uri.encodeComponent(body[k]!)}')
          .join('&'),
    );
    if (response.statusCode != 200) {
      throw Exception(
        'OAuth token exchange failed: ${response.statusCode} ${response.body}',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
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
  static Future<OAuth2TokenResponse> refreshToken({
    required String baseUrl,
    required String clientId,
    required String refreshToken,
    String? clientSecret,
  }) async {
    final path = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final uri = Uri.parse(
      '${path}api/method/frappe.integrations.oauth2.get_token',
    );
    final body = <String, String>{
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientId,
    };
    if (clientSecret != null && clientSecret.isNotEmpty) {
      body['client_secret'] = clientSecret;
    }
    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Accept': 'application/json',
      },
      body: body.keys
          .map((k) => '$k=${Uri.encodeComponent(body[k]!)}')
          .join('&'),
    );
    if (response.statusCode != 200) {
      throw Exception(
        'OAuth refresh failed: ${response.statusCode} ${response.body}',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return OAuth2TokenResponse.fromJson(json);
  }

  /// Verifies [accessToken] by calling the OpenID userinfo endpoint.
  static Future<Map<String, dynamic>> verifyToken({
    required String baseUrl,
    required String accessToken,
  }) async {
    final path = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final uri = Uri.parse(
      '${path}api/method/frappe.integrations.oauth2.openid_profile',
    );
    final response = await http.get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (response.statusCode != 200) {
      throw Exception(
        'Token verification failed: ${response.statusCode} ${response.body}',
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Revokes an access or refresh token.
  static Future<void> revokeToken({
    required String baseUrl,
    required String token,
  }) async {
    final path = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    final uri = Uri.parse(
      '${path}api/method/frappe.integrations.oauth2.revoke_token',
    );
    await http.post(
      uri,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: 'token=${Uri.encodeComponent(token)}',
    );
  }
}
