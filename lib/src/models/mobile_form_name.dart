/// Represents a mobile form name from login response.
class MobileFormName {
  final String mobileDoctype;
  final String? groupName;
  final String? doctypeMetaModifiedAt;
  final String? doctypeIcon;

  const MobileFormName({
    required this.mobileDoctype,
    this.groupName,
    this.doctypeMetaModifiedAt,
    this.doctypeIcon,
  });

  factory MobileFormName.fromJson(Map<String, dynamic> json) {
    return MobileFormName(
      mobileDoctype: json['mobile_doctype'] as String? ?? '',
      groupName: json['group_name'] as String?,
      doctypeMetaModifiedAt: json['doctype_meta_modifed_at'] as String?,
      doctypeIcon: json['doctype_icon'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'mobile_doctype': mobileDoctype,
      if (groupName != null) 'group_name': groupName,
      if (doctypeMetaModifiedAt != null)
        'doctype_meta_modifed_at': doctypeMetaModifiedAt,
      if (doctypeIcon != null) 'doctype_icon': doctypeIcon,
    };
  }
}
