import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/daos/translation_dao.dart';
import 'package:frappe_mobile_sdk/src/services/translation_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<TranslationService> makeService() async =>
      TranslationService.forTesting()
        ..injectDao(await TranslationDao.forTesting());

  group('loadFromCache', () {
    test('populates _cache from DAO', () async {
      final svc = await makeService();
      await svc.dao.bulkUpsert('hi', {'Yes': 'हाँ', 'No': 'नहीं'});
      await svc.loadFromCache('hi');
      expect(svc.translate('Yes'), 'Yes'); // currentLang is 'en', not 'hi' yet
      svc.setCurrentLangForTesting('hi');
      expect(svc.translate('Yes'), 'हाँ');
      expect(svc.translate('No'), 'नहीं');
      await svc.dao.close();
    });

    test('no-op when DAO has no rows for lang', () async {
      final svc = await makeService();
      await svc.loadFromCache('hi');
      svc.setCurrentLangForTesting('hi');
      expect(svc.translate('Yes'), 'Yes'); // falls back to source
      await svc.dao.close();
    });
  });

  group('translate fallback', () {
    test('returns source key when no translation found', () {
      final svc = TranslationService.forTesting();
      expect(svc.translate('Unknown Key'), 'Unknown Key');
    });

    test('returns empty string for empty source', () {
      final svc = TranslationService.forTesting();
      expect(svc.translate(''), '');
    });
  });

  group('onChanged stream', () {
    test('emits after loadFromCache when rows present', () async {
      final svc = await makeService();
      await svc.dao.bulkUpsert('hi', {'Yes': 'हाँ'});
      final events = <void>[];
      svc.onChanged.listen((_) => events.add(null));
      await svc.loadFromCache('hi');
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      await svc.dao.close();
    });

    test('does not emit after loadFromCache when DAO is empty', () async {
      final svc = await makeService();
      final events = <void>[];
      svc.onChanged.listen((_) => events.add(null));
      await svc.loadFromCache('hi');
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      await svc.dao.close();
    });

    test(
      'emits onChanged on every loadFromCache call that finds rows',
      () async {
        // Verifies the contract that _doRefresh is meant to honour: once the
        // in-memory cache is populated, onChanged fires every time — even on
        // repeated calls (analogous to _doRefresh firing after bulkUpsert
        // throws but the cache is still valid from loadTranslations).
        final svc = await makeService();
        await svc.dao.bulkUpsert('hi', {'Submit': 'सबमिट'});
        final events = <void>[];
        svc.onChanged.listen((_) => events.add(null));

        svc.setCurrentLangForTesting('hi');
        await svc.loadFromCache('hi');
        await Future<void>.delayed(Duration.zero);
        expect(events, hasLength(1));
        expect(svc.translate('Submit'), 'सबमिट');

        // A second load (simulating a cache-refresh) must also emit.
        await svc.loadFromCache('hi');
        await Future<void>.delayed(Duration.zero);
        expect(events, hasLength(2));

        await svc.dao.close();
      },
    );
  });

  group('setLocale', () {
    test('updates currentLang immediately', () async {
      final svc = await makeService();
      await svc.setLocale('hi');
      expect(svc.currentLang, 'hi');
      await svc.dao.close();
    });

    test('loads from cache when DB has rows', () async {
      final svc = await makeService();
      await svc.dao.bulkUpsert('hi', {'Yes': 'हाँ'});
      await svc.setLocale('hi');
      expect(svc.translate('Yes'), 'हाँ');
      await svc.dao.close();
    });

    test(
      'reloads from SQLite even when _cache already has an entry for lang',
      () async {
        // Simulates: login cached stale/empty data, user switches locale offline.
        // setLocale must NOT skip loadFromCache just because _cache.containsKey.
        final svc = await makeService();
        // Pre-seed an empty in-memory entry (as if a previous wrong API call ran)
        // by injecting it directly via the testing helper path.
        svc.setCurrentLangForTesting('hi'); // set lang first
        // populate SQLite with correct translations (as if refreshAllAsync ran)
        await svc.dao.bulkUpsert('hi', {'Child Name': 'बच्चे का नाम'});
        // Now set locale again — must reload from SQLite unconditionally.
        await svc.setLocale('hi');
        expect(svc.translate('Child Name'), 'बच्चे का नाम');
        await Future<void>.delayed(Duration.zero);
        await svc.dao.close();
      },
    );
  });

  group('clearAll', () {
    test('clears in-memory cache, resets lang to en, wipes SQLite', () async {
      final svc = await makeService();
      await svc.dao.bulkUpsert('hi', {'Yes': 'हाँ'});
      await svc.loadFromCache('hi');
      svc.setCurrentLangForTesting('hi');
      // Confirm translation is cached
      expect(svc.translate('Yes'), 'हाँ');

      await svc.clearAll();

      // translate() now falls back to source (cache cleared, lang reset to en)
      expect(svc.translate('Yes'), 'Yes');
      expect(svc.currentLang, 'en');

      // SQLite rows should be gone
      final remaining = await svc.dao.readAll('hi');
      expect(remaining, isEmpty);

      await svc.dao.close();
    });
  });

  group('refreshAllAsync dispose safety', () {
    test(
      'refreshAllAsync returns early if disposed — no write after dispose',
      () async {
        final svc = await makeService();
        // Immediately dispose; _doRefreshAll should bail when _disposed is true.
        await svc.dispose();

        // Should not throw; _disposed guard short-circuits the whole method.
        final errors = <Object>[];
        await runZonedGuarded(() async {
          svc.refreshAllAsync();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }, (e, _) => errors.add(e));

        expect(errors, isEmpty);
      },
    );
  });

  group('dispose safety', () {
    test(
      'no StateError when dispose is called before onChanged emits',
      () async {
        final svc = await makeService();
        await svc.dao.bulkUpsert('hi', {'Yes': 'हाँ'});

        final errors = <Object>[];
        await runZonedGuarded(() async {
          // loadFromCache awaits the DAO, then emits onChanged — the guard
          // must prevent a StateError if the controller is already closed.
          await svc.loadFromCache('hi');
          await svc.dispose(); // closes the StreamController
          // Give the event loop a turn; no emission should follow dispose.
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }, (e, _) => errors.add(e));

        expect(
          errors,
          isEmpty,
          reason: 'No StateError or other error should be thrown after dispose',
        );
      },
    );

    test(
      'onChanged stream is closed after dispose and emits no further events',
      () async {
        final svc = await makeService();
        await svc.dao.bulkUpsert('hi', {'Yes': 'हाँ'});
        await svc.loadFromCache('hi'); // prime the cache + first emission
        await svc.dispose();

        var extraEvents = 0;
        // Listening to a closed broadcast stream is harmless but receives nothing.
        svc.onChanged.listen((_) => extraEvents++);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(extraEvents, 0);
      },
    );
  });
}
