// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/attachment_cipher.dart';
import 'rest_helper.dart';
import 'utils.dart';

class AttachmentService {
  final RestHelper _restHelper;

  AttachmentService(this._restHelper);

  /// Uploads [file] to Frappe's `upload_file`.
  ///
  /// A file encrypted at rest by this SDK (`FrappeSDK(encryptAttachments:
  /// true)`, detected by its header) is decrypted in memory and sent through
  /// [uploadBytes]; no plain copy is written to disk. Any other file is
  /// streamed from disk as before.
  Future<Map<String, dynamic>> uploadFile(
    File file, {
    String? fileName,
    String? doctype,
    String? docname,
    bool isPrivate = true,
  }) async {
    if (await AttachmentCipher.isEncryptedFile(file.path)) {
      return uploadBytes(
        await AttachmentCipher.readPlainBytes(file.path),
        fileName: fileName ?? p.basename(file.path),
        doctype: doctype,
        docname: docname,
        isPrivate: isPrivate,
      );
    }
    final fields = _fields(
      fileName: fileName,
      doctype: doctype,
      docname: docname,
      isPrivate: isPrivate,
    );

    final response = await _restHelper.uploadFile(
      '/api/method/upload_file',
      'file',
      file,
      fields: fields,
      // The multipart part name is what Frappe ultimately stores: it overwrites
      // form_dict.file_name whenever a file part is present. Staged files are
      // named <uuid><ext>, so without this every upload lands server-side as an
      // opaque uuid regardless of what the user picked.
      filename: fileName,
    );

    return unwrapMessage<Map<String, dynamic>>(response);
  }

  /// Uploads in-memory [bytes] as [fileName] to Frappe's `upload_file`.
  Future<Map<String, dynamic>> uploadBytes(
    List<int> bytes, {
    required String fileName,
    String? doctype,
    String? docname,
    bool isPrivate = true,
  }) async {
    final response = await _restHelper.uploadBytes(
      '/api/method/upload_file',
      'file',
      bytes,
      filename: fileName,
      fields: _fields(
        fileName: fileName,
        doctype: doctype,
        docname: docname,
        isPrivate: isPrivate,
      ),
    );
    return unwrapMessage<Map<String, dynamic>>(response);
  }

  Map<String, String> _fields({
    String? fileName,
    String? doctype,
    String? docname,
    required bool isPrivate,
  }) {
    final fields = <String, String>{
      'is_private': isPrivate ? '1' : '0',
      'folder': 'Home',
    };

    // Frappe's `upload_file` reads form_dict.doctype / .docname / .file_name —
    // verified against 16.25.0, 16.26.3 and 17.0.0-dev. The older dt/dn/filename
    // keys are silently ignored, which produced a File row that looked attached
    // but was not.
    if (doctype != null && docname != null) {
      fields['doctype'] = doctype;
      fields['docname'] = docname;
    }

    if (fileName != null) {
      fields['file_name'] = fileName;
    }
    return fields;
  }
}
