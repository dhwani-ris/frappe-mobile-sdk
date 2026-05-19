import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/mobile_form_name.dart';

void main() {
  test('fromJson maps mobile_workspace_item and optional fields', () {
    final m = MobileFormName.fromJson({
      'mobile_workspace_item': 'Student Enrollment Form',
      'group_name': 'Admissions',
      'doctype_meta_modifed_at': '2026-01-01',
      'doctype_icon': 'octicon octicon-file',
    });
    expect(m.mobileDoctype, 'Student Enrollment Form');
    expect(m.groupName, 'Admissions');
    expect(m.doctypeMetaModifiedAt, '2026-01-01');
    expect(m.doctypeIcon, 'octicon octicon-file');
  });

  test(
    'fromJson defaults to empty string when mobile_workspace_item absent',
    () {
      final m = MobileFormName.fromJson({});
      expect(m.mobileDoctype, '');
      expect(m.groupName, isNull);
      expect(m.doctypeMetaModifiedAt, isNull);
      expect(m.doctypeIcon, isNull);
    },
  );

  test('toJson round-trips all fields', () {
    const m = MobileFormName(
      mobileDoctype: 'Attendance',
      groupName: 'HR',
      doctypeMetaModifiedAt: '2026-05-01',
      doctypeIcon: 'fa fa-check',
    );
    final j = m.toJson();
    expect(j['mobile_doctype'], 'Attendance');
    expect(j['group_name'], 'HR');
    expect(j['doctype_meta_modifed_at'], '2026-05-01');
    expect(j['doctype_icon'], 'fa fa-check');
  });

  test('toJson omits optional null fields', () {
    const m = MobileFormName(mobileDoctype: 'Customer');
    final j = m.toJson();
    expect(j['mobile_doctype'], 'Customer');
    expect(j.containsKey('group_name'), isFalse);
    expect(j.containsKey('doctype_meta_modifed_at'), isFalse);
    expect(j.containsKey('doctype_icon'), isFalse);
  });
}
