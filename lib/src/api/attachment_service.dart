// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:io';
import 'package:path/path.dart' as p;
import '../utils/image_downscale.dart';
import 'rest_helper.dart';
import 'utils.dart';

/// Image extensions Frappe's `upload_file` resolves to an `image/*` type
/// (`mimetypes.guess_type`), minus SVG, which Desk never optimises.
const Set<String> _optimisableImageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.webp',
  '.bmp',
  '.tif',
  '.tiff',
  '.heic',
  '.heif',
};

/// Desk asks the server to optimise images larger than this
/// (`file_uploader/FileUploader.vue`: `size_kb > 200`).
const int _deskOptimiseThresholdBytes = 200 * 1024;

class AttachmentService {
  final RestHelper _restHelper;

  AttachmentService(this._restHelper);

  Future<Map<String, dynamic>> uploadFile(
    File file, {
    String? fileName,
    String? doctype,
    String? docname,
    bool isPrivate = true,
    bool? optimize,
  }) async {
    final fields = <String, String>{
      'is_private': isPrivate ? '1' : '0',
      'folder': 'Home',
    };

    // Frappe's `upload_file` stores the file as sent unless the client asks it
    // to optimise; then it shrinks an image to at most 1024x768 at quality 85
    // and keeps the smaller copy (frappe/handler.py `upload_file`,
    // frappe/utils/image.py `optimize_image`). Off by default, as in the API.
    // [ImageUploadSettings.serverOptimize] opts in to Desk's rule (an image
    // over 200 KB that is not an SVG); [optimize] forces it on or off for one
    // upload, like Desk's per-file toggle. The flag is only ever sent as true:
    // the server treats any non-empty value as true.
    final name = fileName ?? file.path;
    final isImage = _optimisableImageExtensions.contains(
      p.extension(name).toLowerCase(),
    );
    final wantOptimise =
        optimize ??
        (ImageUploadSettings.serverOptimize &&
            await file.length() > _deskOptimiseThresholdBytes);
    if (isImage && wantOptimise) {
      fields['optimize'] = 'true';
    }

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
}
