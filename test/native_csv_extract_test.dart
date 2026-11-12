import 'package:field_tms/export/export_document.dart';
import 'package:field_tms/export/export_file_saver_native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('field_tms/export');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test(
    'native cancel, read failure, append failure and no space always abort spool',
    () async {
      for (final failure in ['cancel', 'read', 'append', 'space', 'finish']) {
        final calls = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'begin') return {'token': 'spool'};
          if (call.method == 'append' &&
              (failure == 'append' || failure == 'space')) {
            throw PlatformException(
              code: failure == 'space' ? 'export_space' : 'export_failed',
            );
          }
          if (call.method == 'finish') {
            if (failure == 'finish') {
              throw PlatformException(code: 'export_failed');
            }
            return {'status': 'cancelled'};
          }
          return null;
        });
        final result = await NativeExportFileSaver().saveStream(
          fileName: 'study.csv',
          mimeType: 'text/csv',
          write: (sink) async {
            await sink(Uint8List(65536));
            if (failure == 'read') throw StateError('Storage read failed');
            return const ExportSummary(recordCount: 1, byteCount: 65536);
          },
        );
        expect(calls.last, 'abort', reason: failure);
        expect(
          result.status,
          failure == 'cancel'
              ? ExportSaveStatus.cancelled
              : ExportSaveStatus.failed,
        );
        if (failure == 'space') expect(result.message, contains('free space'));
        if (failure == 'read' || failure == 'append' || failure == 'space') {
          expect(calls, isNot(contains('finish')));
        }
      }
    },
  );

  test(
    'pre-cancelled generation never opens a spool; oversized chunks abort',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'begin') return {'token': 'spool'};
        return null;
      });
      final cancelled = ExportCancellation()..cancel();
      final saver = NativeExportFileSaver();
      final result = await saver.saveStream(
        fileName: 'a.csv',
        mimeType: 'text/csv',
        cancellation: cancelled,
        write: (_) async => const ExportSummary(recordCount: 0, byteCount: 0),
      );
      expect(result.status, ExportSaveStatus.cancelled);
      expect(calls, isEmpty);
      final oversized = await saver.saveStream(
        fileName: 'a.csv',
        mimeType: 'text/csv',
        write: (sink) async {
          await sink(Uint8List(65537));
          return const ExportSummary(recordCount: 0, byteCount: 65537);
        },
      );
      expect(oversized.status, ExportSaveStatus.failed);
      expect(calls, ['begin', 'abort']);
    },
  );

  test(
    'native saver reports save, cancellation and unavailable support honestly',
    () async {
      const channel = MethodChannel('field_tms/export');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final document = ExportDocument(
        bytes: Uint8List.fromList([1, 2, 3]),
        fileName: 'study.csv',
        mimeType: 'text/csv',
        recordCount: 1,
      );
      MethodCall? captured;
      messenger.setMockMethodCallHandler(channel, (call) async {
        captured = call;
        return {'status': 'cancelled'};
      });
      final saver = NativeExportFileSaver();
      expect((await saver.save(document)).status, ExportSaveStatus.cancelled);
      expect(captured!.method, 'save');
      final args = captured!.arguments as Map;
      expect(args['fileName'], 'study.csv');
      expect(args['mimeType'], 'text/csv');
      expect(args['bytes'], [1, 2, 3]);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {'status': 'saved'},
      );
      expect((await saver.save(document)).status, ExportSaveStatus.saved);
      messenger.setMockMethodCallHandler(channel, null);
      expect((await saver.save(document)).status, ExportSaveStatus.failed);
    },
  );
}
