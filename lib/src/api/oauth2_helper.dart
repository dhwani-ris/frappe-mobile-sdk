// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// Frappe OAuth 2.0 with PKCE (RFC 7636)

import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Result of PKCE generation
class PkcePair {
  final String codeVerifier;
  final String codeChallenge;

  PkcePair({required this.codeVerifier, required this.codeChallenge});
}

/// Frappe OAuth 2.0 token response
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

/// Helper for Frappe OAuth 2.0 (authorization code + PKCE)
class OAuth2Helper {
  static const String _chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  /// Generate code_verifier (43–128 chars) and code_challenge (S256)
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

  /// Build authorize URL for Frappe
  /// GET /api/method/frappe.integrations.oauth2.authorize
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

  /// Exchange authorization code for tokens (with optional PKCE code_verifier)
  static Future<OAuth2TokenResponse> exchangeCodeForToken({
    required String baseUrl,
    required String clientId,
    required String redirectUri,
    required String code,
    String? codeVerifier,
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
    return OAuth2TokenResponse.fromJson(json);
  }

  /// Refresh access token
  static Future<OAuth2TokenResponse> refreshToken({
    required String baseUrl,
    required String clientId,
    required String refreshToken,
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

  /// Revoke token (access or refresh)
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
