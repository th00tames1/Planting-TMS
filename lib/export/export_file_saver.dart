import 'export_document.dart';
import 'export_file_saver_native.dart'
    if (dart.library.js_interop) 'export_file_saver_web.dart'
    as platform;

export 'export_document.dart';

ExportFileSaver createExportFileSaver() => platform.createExportFileSaver();
