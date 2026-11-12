import 'package:flutter/services.dart';

import 'export_document.dart';

ExportFileSaver createExportFileSaver() => NativeExportFileSaver();

class NativeExportFileSaver implements StreamingExportFileSaver {
  NativeExportFileSaver({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('field_tms/export');
  final MethodChannel _channel;

  @override
  Future<ExportSaveResult> saveStream({
    required String fileName,
    required String mimeType,
    required Future<ExportSummary> Function(ExportByteSink sink) write,
    ExportCancellation? cancellation,
    void Function()? onPrepared,
  }) async {
    String? token;
    try {
      cancellation?.check();
      final opened = await _channel.invokeMapMethod<String, dynamic>('begin', {
        'fileName': fileName,
        'mimeType': mimeType,
      });
      token = opened?['token'] as String?;
      if (token == null || token.isEmpty) {
        throw const ExportException('Could not prepare the export file.');
      }
      await write((bytes) async {
        cancellation?.check();
        if (bytes.length > 64 * 1024) {
          throw const ExportException('The export chunk is too large.');
        }
        await _channel.invokeMethod<void>('append', {
          'token': token,
          'bytes': bytes,
        });
        cancellation?.check();
      });
      cancellation?.check();
      onPrepared?.call();
      final result = await _channel.invokeMapMethod<String, dynamic>('finish', {
        'token': token,
      });
      return _result(result);
    } on ExportCancelledException {
      return const ExportSaveResult(ExportSaveStatus.cancelled);
    } on ExportException catch (error) {
      return ExportSaveResult(ExportSaveStatus.failed, message: error.message);
    } on MissingPluginException {
      return const ExportSaveResult(
        ExportSaveStatus.failed,
        message: 'File saving is unavailable on this platform.',
      );
    } on PlatformException catch (error) {
      return ExportSaveResult(
        ExportSaveStatus.failed,
        message: error.code == 'export_space'
            ? 'Not enough free space to prepare this export. Free some space and try again.'
            : 'Could not save the file. Choose a location and try again.',
      );
    } catch (_) {
      return const ExportSaveResult(
        ExportSaveStatus.failed,
        message: 'Could not export this study. Try again.',
      );
    } finally {
      if (token != null) {
        // Native finish also cleans up. Abort is idempotent and covers read,
        // generation, channel, picker, and cancellation failures.
        try {
          await _channel.invokeMethod<void>('abort', {'token': token});
        } catch (_) {
          /* Preserve the original result if cleanup is unavailable. */
        }
      }
    }
  }

  ExportSaveResult _result(Map<String, dynamic>? result) {
    if (result?['status'] == 'saved') {
      return const ExportSaveResult(ExportSaveStatus.saved);
    }
    if (result?['status'] == 'cancelled') {
      return const ExportSaveResult(ExportSaveStatus.cancelled);
    }
    return const ExportSaveResult(
      ExportSaveStatus.failed,
      message: 'The file was not saved. Try again.',
    );
  }

  @override
  Future<ExportSaveResult> save(ExportDocument document) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('save', {
        'fileName': document.fileName,
        'mimeType': document.mimeType,
        'bytes': document.bytes,
      });
      if (result?['status'] == 'saved') {
        return const ExportSaveResult(ExportSaveStatus.saved);
      }
      if (result?['status'] == 'cancelled') {
        return const ExportSaveResult(ExportSaveStatus.cancelled);
      }
      return const ExportSaveResult(
        ExportSaveStatus.failed,
        message: 'The file was not saved. Try again.',
      );
    } on MissingPluginException {
      return const ExportSaveResult(
        ExportSaveStatus.failed,
        message: 'File saving is unavailable on this platform.',
      );
    } on PlatformException {
      return const ExportSaveResult(
        ExportSaveStatus.failed,
        message: 'Could not save the file. Choose a location and try again.',
      );
    } catch (_) {
      return const ExportSaveResult(
        ExportSaveStatus.failed,
        message: 'Could not save the file. Try again.',
      );
    }
  }
}
