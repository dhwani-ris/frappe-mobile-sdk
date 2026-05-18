import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/services/translation_service.dart';

http.Client _scripted(
  Map<String, Map<String, dynamic>> langToTranslations, {
  List<Map<String, dynamic>>? sentSink,
  http.Response? overrideAll,
}) {
  return MockClient((req) async {
    sentSink?.add({'method': req.method, 'url': req.url.toString()});
    if (overrideAll != null) return overrideAll;
    final body = {
      'data': {
        'langs': langToTranslations.keys.toList(),
        'translations': langToTranslations,
      },
    };
    // Force lang-specific data shape so missing-lang test still returns the full envelope.
    return http.Response(jsonEncode(body), 200);
  });
}

void main() {
  test('default currentLang is "en"', () {
    final svc = TranslationService(FrappeClient('http://localhost'));
    expect(svc.currentLang, 'en');
  });

  test('translate returns source when no cache exists', () {
    final svc = TranslationService(FrappeClient('http://localhost'));
    expect(svc.translate('Hello'), 'Hello');
  });

  test('translate returns empty when source is empty', () {
    final svc = TranslationService(FrappeClient('http://localhost'));
    expect(svc.translate(''), '');
  });

  test(
    'loadTranslations parses {data.translations.<lang>} and caches',
    () async {
      final client = FrappeClient(
        'http://localhost',
        httpClient: _scripted({
          'hr': {'Hello': 'Bok', 'Bye': 'Bye-hr'},
        }),
      );
      final svc = TranslationService(client);
      final map = await svc.loadTranslations('hr');
      expect(map, {'Hello': 'Bok', 'Bye': 'Bye-hr'});
      // Cached:
      expect(svc.getCachedTranslations('hr'), {
        'Hello': 'Bok',
        'Bye': 'Bye-hr',
      });
    },
  );

  test('loadTranslations returns empty map when lang not in payload', () async {
    final client = FrappeClient(
      'http://localhost',
      httpClient: _scripted({
        'hr': {'Hello': 'Bok'},
      }),
    );
    final svc = TranslationService(client);
    final map = await svc.loadTranslations('xx');
    expect(map, isEmpty);
  });

  test(
    'loadTranslations returns empty map on non-map server response',
    () async {
      final client = FrappeClient(
        'http://localhost',
        httpClient: MockClient(
          (_) async => http.Response('"unexpected-string"', 200),
        ),
      );
      final svc = TranslationService(client);
      final map = await svc.loadTranslations('hr');
      expect(map, isEmpty);
    },
  );

  test('loadTranslations swallows server errors and returns empty', () async {
    final client = FrappeClient(
      'http://localhost',
      httpClient: MockClient((_) async => http.Response('boom', 500)),
    );
    final svc = TranslationService(client);
    final map = await svc.loadTranslations('hr');
    expect(map, isEmpty);
  });

  test(
    'setLocale updates currentLang and triggers a load on first use',
    () async {
      final calls = <Map<String, dynamic>>[];
      final client = FrappeClient(
        'http://localhost',
        httpClient: _scripted({
          'my': {'Yes': 'Yes-my'},
        }, sentSink: calls),
      );
      final svc = TranslationService(client);
      await svc.setLocale('my');
      expect(svc.currentLang, 'my');
      expect(calls, hasLength(1));
      expect(calls.single['url'], contains('lang=my'));

      // Second setLocale to the same lang should hit cache, no extra request.
      await svc.setLocale('my');
      expect(calls, hasLength(1));
    },
  );

  test('setLocale ignores empty string', () async {
    final svc = TranslationService(FrappeClient('http://localhost'));
    await svc.setLocale('');
    expect(svc.currentLang, 'en');
  });

  test('translate after loadTranslations uses cached translation', () async {
    final client = FrappeClient(
      'http://localhost',
      httpClient: _scripted({
        'en': {'Hello': 'Howdy'},
      }),
    );
    final svc = TranslationService(client);
    await svc.loadTranslations('en');
    expect(svc.translate('Hello'), 'Howdy');
    expect(
      svc.translate('Unknown'),
      'Unknown',
      reason: 'missing keys fall back to the source string',
    );
  });

  test('translate substitutes positional placeholders', () async {
    final client = FrappeClient(
      'http://localhost',
      httpClient: _scripted({
        'en': {'Welcome {0}, age {1}': 'Hi {0}, you are {1}'},
      }),
    );
    final svc = TranslationService(client);
    await svc.loadTranslations('en');
    expect(
      svc.translate('Welcome {0}, age {1}', ['Ada', 36]),
      'Hi Ada, you are 36',
    );
  });

  test('call() is an alias for translate', () async {
    final client = FrappeClient(
      'http://localhost',
      httpClient: _scripted({
        'en': {'Hello': 'Howdy'},
      }),
    );
    final svc = TranslationService(client);
    await svc.loadTranslations('en');
    expect(svc('Hello'), 'Howdy');
  });

  test('getCachedTranslations returns a defensive copy', () async {
    final client = FrappeClient(
      'http://localhost',
      httpClient: _scripted({
        'en': {'A': '1'},
      }),
    );
    final svc = TranslationService(client);
    await svc.loadTranslations('en');
    final snapshot = svc.getCachedTranslations('en');
    snapshot['A'] = 'mutated';
    expect(
      svc.translate('A'),
      '1',
      reason: 'caller mutation must not leak into cache',
    );
  });
}
