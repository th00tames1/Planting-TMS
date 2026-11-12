import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'export_document.dart';

ExportFileSaver createExportFileSaver() => BrowserExportFileSaver();

class BrowserExportFileSaver implements ExportFileSaver {
  @override
  Future<ExportSaveResult> save(ExportDocument document) async {
    String? url;
    try {
      final blob = web.Blob(
        [document.bytes.toJS].toJS,
        web.BlobPropertyBag(type: document.mimeType),
      );
      url = web.URL.createObjectURL(blob);
      final anchor = web.HTMLAnchorElement()
        ..href = url
        ..download = document.fileName
        ..style.display = 'none';
      web.document.body?.append(anchor);
      anchor.click();
      anchor.remove();
      final downloadUrl = url;
      Timer(
        const Duration(seconds: 2),
        () => web.URL.revokeObjectURL(downloadUrl),
      );
      return const ExportSaveResult(
        ExportSaveStatus.downloadStarted,
        message: 'Download started. Check your browser downloads.',
      );
    } catch (_) {
      if (url != null) web.URL.revokeObjectURL(url);
      return const ExportSaveResult(
        ExportSaveStatus.failed,
        message: 'The browser could not start this download. Try again.',
      );
    }
  }
}
