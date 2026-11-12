import 'dart:typed_data';

class ExportDocument {
  const ExportDocument({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
    required this.recordCount,
  });

  final Uint8List bytes;
  final String fileName;
  final String mimeType;
  final int recordCount;
}

class ExportException implements Exception {
  const ExportException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum ExportSaveStatus { saved, downloadStarted, cancelled, failed }

class ExportSaveResult {
  const ExportSaveResult(this.status, {this.message});
  final ExportSaveStatus status;
  final String? message;
}

abstract class ExportFileSaver {
  Future<ExportSaveResult> save(ExportDocument document);
}

/// The sink consumes each chunk before completing. Producers apply backpressure;
/// a sink must not retain chunks after completion unless it copies them.
typedef ExportByteSink = Future<void> Function(Uint8List bytes);

class ExportSummary {
  const ExportSummary({required this.recordCount, required this.byteCount});
  final int recordCount;
  final int byteCount;
}

class ExportCancellation {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
  void check() {
    if (_cancelled) throw const ExportCancelledException();
  }
}

class ExportCancelledException implements Exception {
  const ExportCancelledException();
}

/// Native implementations spool chunks before presenting the save picker.
abstract class StreamingExportFileSaver implements ExportFileSaver {
  Future<ExportSaveResult> saveStream({
    required String fileName,
    required String mimeType,
    required Future<ExportSummary> Function(ExportByteSink sink) write,
    ExportCancellation? cancellation,
    void Function()? onPrepared,
  });
}
