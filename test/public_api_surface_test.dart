// Guards the two attachment-media types a HOST must be able to name.
//
// This file imports ONLY the public entry point, because that is all a host
// gets: reaching into `package:frappe_mobile_sdk/src/...` trips the
// `implementation_imports` lint. Both types were reachable from inside the
// package and unreachable from outside it, which no other test could detect —
// every existing test imports `src/` directly.
//
// `ImagePickSource` is the load-bearing one: wiring `FormScreen.imagePickSource`
// means PRODUCING a value, so type inference cannot stand in for the export the
// way it can for a returned value.
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() {
  test('a host can name ImagePickSource to wire the pick-source hook', () {
    // The return-type annotation is the assertion: this is the shape
    // `FormScreen.imagePickSource` takes, and it does not compile unless the
    // enum is exported.
    ImagePickSource hook() => ImagePickSource.camera;
    expect(hook(), ImagePickSource.camera);
    expect(ImagePickSource.camera.allowsCamera, isTrue);
    expect(ImagePickSource.camera.allowsGallery, isFalse);
    expect(ImagePickSource.both.allowsGallery, isTrue);
  });

  test(
    'a host can name MediaStoreUsage to hold what mediaStoreUsage returns',
    () {
      const MediaStoreUsage usage = MediaStoreUsage(
        outboxBytes: 10,
        cacheBytes: 5,
        orphanBytes: 4,
        orphanCount: 1,
      );
      expect(usage.totalBytes, 15, reason: 'orphanBytes is a subset of outbox');
    },
  );

  test('a host can name ResolveMediaFn to override FieldFactory.createField', () {
    // `FieldFactory` is exported bare and documented as overridable, and its
    // `createField` takes a `ResolveMediaFn? mediaResolver`. Overriding it means
    // WRITING the type out, which inference cannot stand in for — the same shape
    // of problem as `ImagePickSource` above. The annotation is the assertion:
    // this does not compile unless the typedef is exported.
    ResolveMediaFn? resolver;
    expect(resolver, isNull);

    // And it must be usable AS the annotated type, not merely nameable.
    resolver = (String value, {Map<int, String>? pendingPaths}) async =>
        pendingPaths?[1] ?? value;
    expect(resolver, isNotNull);
  });
}
