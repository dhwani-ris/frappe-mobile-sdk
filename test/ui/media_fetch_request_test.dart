// The media resolver's fetcher (`FormScreen._fetchMediaBytes`) used to attach
// the session headers to every URL it fetched. A file value can be an absolute
// URL on object storage or a CDN, so opening a form sent the session token to
// that host. The request is now built by [mediaFetchRequest], which sends the
// headers to the Frappe origin only.
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/ui/form_screen.dart';

void main() {
  const base = 'https://site.example.com';
  const auth = {'Authorization': 'token k:s', 'X-Frappe-Site-Name': 'site'};

  test('an off-host absolute URL is fetched without the session headers', () {
    final req = mediaFetchRequest(
      'https://bucket.s3.amazonaws.com/a.jpg',
      baseUrl: base,
      headers: auth,
    )!;
    expect(req.url.host, 'bucket.s3.amazonaws.com');
    expect(req.headers.containsKey('Authorization'), isFalse);
    expect(req.headers.containsKey('X-Frappe-Site-Name'), isFalse);
  });

  test('a Frappe file path goes to the site with the session headers', () {
    final req = mediaFetchRequest(
      '/private/files/a.jpg',
      baseUrl: base,
      headers: auth,
    )!;
    expect(req.url.host, 'site.example.com');
    expect(req.url.path, '/api/method/frappe.handler.download_file');
    expect(req.headers['Authorization'], 'token k:s');
  });

  test('an absolute URL on the Frappe host keeps the session headers', () {
    final req = mediaFetchRequest(
      '$base/files/a.jpg',
      baseUrl: base,
      headers: auth,
    )!;
    expect(req.headers['Authorization'], 'token k:s');
  });

  test('a value that is not a fetchable URL gives no request', () {
    expect(
      mediaFetchRequest('pending:abc', baseUrl: base, headers: auth),
      isNull,
    );
    expect(mediaFetchRequest('', baseUrl: base, headers: auth), isNull);
  });
}
