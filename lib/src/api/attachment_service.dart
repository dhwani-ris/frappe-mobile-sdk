// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:io';
import 'rest_helper.dart';

class AttachmentService {
  final RestHelper _restHelper;

  AttachmentService(this._restHelper);

  Future<Map<String, dynamic>> uploadFile(
    File file, {
    String? fileName,
    String? doctype,
    String? docname,
    bool isPrivate = true,
  }) async {
    final fields = <String, String>{
      'is_private': isPrivate ? '1' : '0',
      'folder': 'Home',
    };

    if (doctype != null && docname != null) {
      fields['dt'] = doctype;
      fields['dn'] = docname;
    }

    if (fileName != null) {
      fields['filename'] = fileName;
    }

    final response = await _restHelper.uploadFile(
      '/api/method/upload_file',
      'file',
      file,
      fields: fields,
    );

    if (response is Map<String, dynamic> && response.containsKey('message')) {
      return response['message'] as Map<String, dynamic>;
    }
    return response as Map<String, dynamic>;
  }
}
