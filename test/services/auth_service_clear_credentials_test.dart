import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/services/auth_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'clearCredentials deletes credentials but keeps the attachment key',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'frappe_api_key': 'k',
        'frappe_api_secret': 's',
        'frappe_oauth_access_token': 't',
        'frappe_sdk_attachment_key__myapp': 'attachment-key',
      });
      await AuthService().clearCredentials();
      final left = await const FlutterSecureStorage().readAll();
      expect(left, {'frappe_sdk_attachment_key__myapp': 'attachment-key'});
    },
  );

  test('only the SDK encryption keys are kept', () {
    expect(AuthService.isSdkEncryptionKey('frappe_sdk_attachment_key'), isTrue);
    expect(
      AuthService.isSdkEncryptionKey('frappe_sdk_attachment_key__app'),
      isTrue,
    );
    expect(AuthService.isSdkEncryptionKey('frappe_api_secret'), isFalse);
  });
}
