import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/attachment_paths.dart';

void main() {
  group('isLocalAttachmentPath', () {
    test('local paths are true', () {
      expect(isLocalAttachmentPath('/data/user/0/app/files/IMG.jpg'), isTrue);
      expect(isLocalAttachmentPath('/storage/emulated/0/x.pdf'), isTrue);
      expect(
        isLocalAttachmentPath('/data/user/0/com.app/mform_attachments/a.png'),
        isTrue,
      );
    });

    test('server urls are false', () {
      for (final v in [
        '/files/a.png',
        '/private/files/a.png',
        'http://h/f.png',
        'https://h/f.png',
        '/api/method/frappe.handler.download_file?file_url=%2Ffiles%2Fa.png',
      ]) {
        expect(isLocalAttachmentPath(v), isFalse, reason: v);
      }
    });

    test('pending markers are false (re-save safety)', () {
      expect(isLocalAttachmentPath('pending:5'), isFalse);
      expect(isLocalAttachmentPath('pending:12345'), isFalse);
    });

    test('null / non-string / empty are false', () {
      expect(isLocalAttachmentPath(null), isFalse);
      expect(isLocalAttachmentPath(''), isFalse);
      expect(isLocalAttachmentPath('   '), isFalse);
      expect(isLocalAttachmentPath(42), isFalse);
    });
  });

  group('parsePendingMarkerId', () {
    test('parses valid markers', () {
      expect(parsePendingMarkerId('pending:1'), 1);
      expect(parsePendingMarkerId('pending:42'), 42);
    });
    test('rejects non-markers', () {
      expect(parsePendingMarkerId('/files/a.png'), isNull);
      expect(parsePendingMarkerId('pending:abc'), isNull);
      expect(parsePendingMarkerId('pending:'), isNull);
      expect(parsePendingMarkerId(null), isNull);
      expect(parsePendingMarkerId(7), isNull);
    });
  });

  group('attachmentDisplaySource', () {
    test('resolves a pending marker to its local path', () {
      expect(
        attachmentDisplaySource('pending:1', {1: '/appdir/a.jpg'}),
        '/appdir/a.jpg',
      );
    });
    test('unknown pending id -> null (broken placeholder, value kept)', () {
      expect(attachmentDisplaySource('pending:9', {1: '/a'}), isNull);
      expect(attachmentDisplaySource('pending:1', null), isNull);
    });
    test('server urls and local paths pass through unchanged', () {
      expect(attachmentDisplaySource('/files/x.png', null), '/files/x.png');
      expect(attachmentDisplaySource('/data/local.jpg', {}), '/data/local.jpg');
      expect(attachmentDisplaySource('https://h/f.png', {}), 'https://h/f.png');
    });
    test('null / empty -> null', () {
      expect(attachmentDisplaySource(null, {}), isNull);
      expect(attachmentDisplaySource('', {}), isNull);
      expect(attachmentDisplaySource('   ', {}), isNull);
    });
  });

  // `AttachField._fullFileUrl` and `ImageField._fullImageUrl` now delegate here,
  // so this is the single point of failure for the private-file auth path: a
  // `/private/files/` value that does NOT route through `download_file` loses
  // its auth and 404s. Every branch is pinned.
  group('frappeFileFetchUrl', () {
    const base = 'https://site.example.com';

    test('private and public files route through download_file for auth', () {
      expect(
        frappeFileFetchUrl('/private/files/a b.png', base),
        '$base/api/method/frappe.handler.download_file'
        '?file_url=%2Fprivate%2Ffiles%2Fa%20b.png',
        reason: 'the value must be percent-encoded into the query',
      );
      expect(
        frappeFileFetchUrl('/files/a.png', base),
        '$base/api/method/frappe.handler.download_file'
        '?file_url=%2Ffiles%2Fa.png',
      );
    });

    test('absolute http(s) urls pass through untouched (S3 and friends)', () {
      expect(frappeFileFetchUrl('http://h/f.png', base), 'http://h/f.png');
      expect(frappeFileFetchUrl('https://h/f.png', base), 'https://h/f.png');
    });

    test('any other rooted path just gets the base prepended', () {
      expect(frappeFileFetchUrl('/assets/x.png', base), '$base/assets/x.png');
    });

    test('a trailing slash on the base is not doubled', () {
      expect(
        frappeFileFetchUrl('/assets/x.png', '$base/'),
        '$base/assets/x.png',
      );
    });

    test('without a usable base the input is returned unchanged', () {
      // Degrade to "not fetchable" rather than building a broken request.
      expect(frappeFileFetchUrl('/files/a.png', null), '/files/a.png');
      expect(frappeFileFetchUrl('/files/a.png', '   '), '/files/a.png');
    });

    test('a relative path is returned unchanged', () {
      expect(frappeFileFetchUrl('files/a.png', base), 'files/a.png');
    });

    test('null and empty are returned as given', () {
      expect(frappeFileFetchUrl(null, base), isNull);
      expect(frappeFileFetchUrl('', base), '');
    });

    test('surrounding whitespace is trimmed before classification', () {
      expect(
        frappeFileFetchUrl('  /files/a.png  ', base),
        '$base/api/method/frappe.handler.download_file'
        '?file_url=%2Ffiles%2Fa.png',
      );
    });
  });
}
