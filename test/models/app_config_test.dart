import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/app_config.dart';

void main() {
  group('SocialProviderConfig', () {
    test('fromJson parses id/label/iconUrl camelCase keys', () {
      final p = SocialProviderConfig.fromJson({
        'id': 'google',
        'label': 'Google',
        'iconUrl': 'https://example.com/google.png',
      });
      expect(p.id, 'google');
      expect(p.label, 'Google');
      expect(p.iconUrl, 'https://example.com/google.png');
    });

    test('fromJson falls back to provider key when id/label absent', () {
      final p = SocialProviderConfig.fromJson({'provider': 'github'});
      expect(p.id, 'github');
      expect(p.label, 'github');
      expect(p.iconUrl, isNull);
    });

    test('fromJson accepts icon/icon_url fallbacks for iconUrl', () {
      final p = SocialProviderConfig.fromJson({
        'id': 'fb',
        'label': 'Facebook',
        'icon': '/static/fb.png',
      });
      expect(p.iconUrl, '/static/fb.png');
    });

    test('toJson round-trips all fields', () {
      const p = SocialProviderConfig(
        id: 'google',
        label: 'Google',
        iconUrl: 'https://g.co/icon.png',
      );
      final j = p.toJson();
      expect(j['id'], 'google');
      expect(j['label'], 'Google');
      expect(j['iconUrl'], 'https://g.co/icon.png');
    });

    test('toJson omits iconUrl when null', () {
      const p = SocialProviderConfig(id: 'x', label: 'X');
      expect(p.toJson().containsKey('iconUrl'), isFalse);
    });
  });

  group('LoginConfig', () {
    test('fromJson defaults — all false except enablePasswordLogin', () {
      final lc = LoginConfig.fromJson({});
      expect(lc.enablePasswordLogin, isTrue);
      expect(lc.enableOAuth, isFalse);
      expect(lc.enableSocialLogin, isFalse);
      expect(lc.enableMobileLogin, isFalse);
      expect(lc.autoDiscoverSocialProviders, isTrue);
      expect(lc.socialProviders, isEmpty);
    });

    test('fromJson parses socialProviders list', () {
      final lc = LoginConfig.fromJson({
        'enableSocialLogin': true,
        'socialProviders': [
          {'id': 'google', 'label': 'Google'},
        ],
      });
      expect(lc.enableSocialLogin, isTrue);
      expect(lc.socialProviders.length, 1);
      expect(lc.socialProviders.first.id, 'google');
    });

    test('toJson round-trips OAuth fields', () {
      const lc = LoginConfig(
        enableOAuth: true,
        oauthClientId: 'client-id',
        oauthClientSecret: 'secret',
      );
      final j = lc.toJson();
      expect(j['enableOAuth'], isTrue);
      expect(j['oauthClientId'], 'client-id');
      expect(j['oauthClientSecret'], 'secret');
    });

    test('toJson omits null oauth fields', () {
      const lc = LoginConfig();
      final j = lc.toJson();
      expect(j.containsKey('oauthClientId'), isFalse);
      expect(j.containsKey('oauthClientSecret'), isFalse);
    });
  });

  group('AppConfig.fromJson', () {
    test('parses baseUrl and doctypes', () {
      final cfg = AppConfig.fromJson({
        'baseUrl': 'https://erp.example.com',
        'doctypes': ['Customer', 'Sales Order'],
      });
      expect(cfg.baseUrl, 'https://erp.example.com');
      expect(cfg.doctypes, ['Customer', 'Sales Order']);
      expect(cfg.loginConfig, isNull);
    });

    test('parses nested loginConfig', () {
      final cfg = AppConfig.fromJson({
        'baseUrl': 'https://erp.example.com',
        'doctypes': [],
        'loginConfig': {'enableMobileLogin': true},
      });
      expect(cfg.loginConfig, isNotNull);
      expect(cfg.enableMobileLogin, isTrue);
    });

    test('toJson omits loginConfig when null', () {
      final cfg = AppConfig(
        baseUrl: 'https://erp.example.com',
        doctypes: ['X'],
      );
      expect(cfg.toJson().containsKey('loginConfig'), isFalse);
    });

    test('toJson includes loginConfig when present', () {
      final cfg = AppConfig(
        baseUrl: 'https://erp.example.com',
        doctypes: [],
        loginConfig: const LoginConfig(enableMobileLogin: true),
      );
      final j = cfg.toJson();
      expect(j.containsKey('loginConfig'), isTrue);
    });
  });

  group('AppConfig.fromJsonFile', () {
    test('parses snake_case keys', () {
      final cfg = AppConfig.fromJsonFile({
        'base_url': 'https://erp.example.com',
        'doctypes': ['Customer'],
        'login_config': {
          'enable_password_login': false,
          'enable_oauth': true,
          'oauth_client_id': 'cid',
          'oauth_client_secret': 'sec',
          'enable_social_login': true,
          'enable_mobile_login': true,
          'auto_discover_social_providers': false,
          'social_providers': [
            {'id': 'google', 'label': 'Google'},
          ],
        },
      });
      expect(cfg.baseUrl, 'https://erp.example.com');
      expect(cfg.enablePasswordLogin, isFalse);
      expect(cfg.enableOAuth, isTrue);
      expect(cfg.oauthClientId, 'cid');
      expect(cfg.oauthClientSecret, 'sec');
      expect(cfg.enableSocialLogin, isTrue);
      expect(cfg.enableMobileLogin, isTrue);
      expect(cfg.loginConfig!.autoDiscoverSocialProviders, isFalse);
      expect(cfg.loginConfig!.socialProviders.first.id, 'google');
    });

    test('falls back to camelCase keys', () {
      final cfg = AppConfig.fromJsonFile({
        'baseUrl': 'https://erp.example.com',
        'doctypes': [],
        'loginConfig': {'enablePasswordLogin': false},
      });
      expect(cfg.enablePasswordLogin, isFalse);
    });

    test('no login_config yields null loginConfig and default getters', () {
      final cfg = AppConfig.fromJsonFile({
        'base_url': 'https://erp.example.com',
        'doctypes': [],
      });
      expect(cfg.loginConfig, isNull);
      expect(cfg.enablePasswordLogin, isTrue);
      expect(cfg.enableOAuth, isFalse);
      expect(cfg.oauthClientId, isNull);
      expect(cfg.oauthClientSecret, isNull);
    });

    test('missing base_url falls back to empty string', () {
      final cfg = AppConfig.fromJsonFile({'doctypes': []});
      expect(cfg.baseUrl, '');
    });
  });
}
