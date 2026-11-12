import 'package:field_tms/actions/app_updates.dart';
import 'package:field_tms/actions/action_recorder.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'action_capture_test.dart' show MemoryJournal, TestClock, TestLocation;
import 'study_management_test.dart' show TestAudio;
import 'package:field_tms/motion/motion_tracker.dart';
import 'capture_test_pump.dart';

class RunningRecorder extends ActionRecorder {
  RunningRecorder()
    : super(
        MemoryJournal(),
        clock: TestClock(),
        location: TestLocation(),
        motion: UnavailableMotionTracker(),
        audio: TestAudio(),
      );
  @override
  bool get running => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppUpdates.channel, (call) async {
          calls.add(call);
          return {
            'supported': true,
            'automatic': true,
            'versionName': '1.1.0',
            'versionCode': 1,
            'available': true,
            'latestVersion': '1.1.1',
          };
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppUpdates.channel, null),
  );
  test(
    'automatic check uses a fixed public repository and allows offline capture',
    () async {
      await AppUpdates().autoCheck();
      expect(calls.single.method, 'check');
      expect(calls.single.arguments, {
        'repository': updateRepository,
        'force': false,
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            AppUpdates.channel,
            (_) async => throw PlatformException(code: 'offline'),
          );
      await AppUpdates()
          .autoCheck(); // A network failure never escapes into capture.
    },
  );
  testWidgets(
    'available update cannot launch an installer during a running study',
    (tester) async {
      final c = RunningRecorder();
      await tester.pumpWidget(MaterialApp(home: AppSettings(recorder: c)));
      await pumpCaptureUi(tester);
      final button = find.widgetWithText(FilledButton, 'Download and install');
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(calls.any((call) => call.method == 'install'), false);
      expect(c.running, true);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
