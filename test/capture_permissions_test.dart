import 'package:field_tms/actions/capture_permissions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('field_tms/permissions');
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  test(
    'startup permission gateway and explicit Settings use separate commands',
    () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return null;
          });
      await prepareCapturePermissions();
      expect(calls, ['prepare']);
      await openCapturePermissionSettings();
      expect(calls, ['prepare', 'openSettings']);
    },
  );
  test(
    'unavailable permission preparation cannot block opening a study',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => throw PlatformException(code: 'unavailable'),
          );
      await prepareCapturePermissions();
    },
  );
}
