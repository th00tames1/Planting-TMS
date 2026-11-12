import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:field_tms/actions/capture_sensors.dart';
import 'package:field_tms/actions/field_location.dart';
import 'package:field_tms/motion/motion_tracker.dart';

MotionReading reading(String id, MotionStatus status) => MotionReading(
  sessionId: id,
  status: status,
  steps: 7,
  distanceM: 4.9,
  stepLengthM: .7,
  source: MotionSource.androidStepCounter,
  observedAtEpochMs: 1700000000000,
);

class ControlledMotion implements MotionTracker {
  final calls = <String>[];
  Completer<MotionReading>? firstStart;
  Completer<void>? firstPause;
  String? activeId;
  int starts = 0;
  bool throwNext = false;
  @override
  Future<MotionReading> read() async => const MotionReading.unavailable();
  @override
  Stream<MotionReading> get readings => const Stream.empty();
  @override
  Future<MotionReading> start({
    required String sessionId,
    double? stepLengthM,
  }) async {
    calls.add('start:$sessionId');
    starts++;
    if (throwNext) {
      throwNext = false;
      throw StateError('Native transport closed');
    }
    if (starts == 1 && firstStart != null) return firstStart!.future;
    activeId = sessionId;
    return reading(sessionId, MotionStatus.running);
  }

  @override
  Future<MotionReading> pause({required String sessionId}) async {
    calls.add('pause:$sessionId');
    if (firstPause != null) {
      final pause = firstPause!;
      await pause.future;
      firstPause = null;
      if (firstStart != null && !firstStart!.isCompleted) {
        firstStart!.complete(reading(sessionId, MotionStatus.paused));
      }
    }
    if (activeId == sessionId) activeId = null;
    return reading(sessionId, MotionStatus.paused);
  }

  @override
  Future<MotionReading> setStepLength({double? stepLengthM}) async =>
      const MotionReading.unavailable();
  @override
  Future<void> dispose() async {}
}

class ControlledLocation extends FieldLocation {
  final calls = <String>[];
  Completer<void>? delayedStart;
  Completer<void>? delayedStop;
  bool active = false;
  @override
  Future<void> start() async {
    calls.add('start');
    final barrier = delayedStart;
    delayedStart = null;
    await barrier?.future;
    active = true;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    final barrier = delayedStop;
    delayedStop = null;
    await barrier?.future;
    active = false;
  }

  @override
  Future<void> enable() async {
    calls.add('enable');
    active = true;
  }
}

Future<void> drain() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'a direct owner change pauses the previous study before starting the next',
    () async {
      final motion = ControlledMotion();
      final location = ControlledLocation();
      final sensors = CaptureSensors(
        motion: motion,
        location: location,
        onReading: (_) {},
      );
      sensors.setRunning('study-a');
      await sensors.settled;
      sensors.setRunning('study-b');
      await sensors.settled;
      expect(motion.calls, ['start:study-a', 'pause:study-a', 'start:study-b']);
      expect(motion.activeId, 'study-b');
      await sensors.close(stop: true);
      location.dispose();
    },
  );
  test(
    'rapid Stop/Resume cancels pending permission before starting again',
    () async {
      final motion = ControlledMotion()
        ..firstStart = Completer<MotionReading>()
        ..firstPause = Completer<void>();
      final location = ControlledLocation();
      final samples = <MotionReading>[];
      final sensors = CaptureSensors(
        motion: motion,
        location: location,
        onReading: samples.add,
      );
      sensors.setRunning('study-a', stepLengthM: .7);
      await drain();
      expect(motion.starts, 1);
      sensors.setRunning(null);
      await drain();
      sensors.setRunning('study-a', stepLengthM: .7);
      await drain();
      expect(
        motion.starts,
        1,
        reason:
            'Resume must wait for cancelled Start and pause acknowledgement.',
      );
      motion.firstPause!.complete();
      await sensors.settled;
      expect(motion.starts, 2);
      expect(motion.activeId, 'study-a');
      expect(samples.last.status, MotionStatus.running);
      expect(location.active, true);
      await sensors.close(stop: true);
      expect(motion.activeId, isNull);
      expect(location.active, false);
      location.dispose();
    },
  );

  test('late GPS stop cannot switch off a resumed study', () async {
    final motion = ControlledMotion();
    final location = ControlledLocation();
    final sensors = CaptureSensors(
      motion: motion,
      location: location,
      onReading: (_) {},
    );
    sensors.setRunning('study-a');
    await sensors.settled;
    final stop = Completer<void>();
    location.delayedStop = stop;
    sensors.setRunning(null);
    await drain();
    sensors.setRunning('study-a');
    await drain();
    expect(location.calls, ['start', 'stop']);
    stop.complete();
    await sensors.settled;
    expect(location.calls, ['start', 'stop', 'start']);
    expect(location.active, true);
    await sensors.close(stop: true);
    location.dispose();
  });

  test(
    'late GPS start is followed by Stop when capture has already stopped',
    () async {
      final motion = ControlledMotion();
      final location = ControlledLocation();
      final start = Completer<void>();
      location.delayedStart = start;
      final sensors = CaptureSensors(
        motion: motion,
        location: location,
        onReading: (_) {},
      );
      sensors.setRunning('study-a');
      await drain();
      sensors.setRunning(null);
      start.complete();
      await sensors.settled;
      expect(location.calls, ['start', 'stop']);
      expect(location.active, false);
      expect(motion.activeId, isNull);
      await sensors.close(stop: true);
      location.dispose();
    },
  );

  test(
    'changing studies waits for old motion cancellation and keeps new owner active',
    () async {
      final motion = ControlledMotion()
        ..firstStart = Completer<MotionReading>()
        ..firstPause = Completer<void>();
      final location = ControlledLocation();
      final sensors = CaptureSensors(
        motion: motion,
        location: location,
        onReading: (_) {},
      );
      sensors.setRunning('study-a');
      await drain();
      sensors.setRunning(null);
      await drain();
      sensors.setRunning('study-b', stepLengthM: .7);
      motion.firstPause!.complete();
      await sensors.settled;
      expect(motion.activeId, 'study-b');
      expect(motion.calls.last, 'start:study-b');
      await sensors.close(stop: true);
      location.dispose();
    },
  );

  test(
    'transport failure is explicit and next Stop/Resume can retry',
    () async {
      final motion = ControlledMotion()..throwNext = true;
      final location = ControlledLocation();
      final samples = <MotionReading>[];
      final sensors = CaptureSensors(
        motion: motion,
        location: location,
        onReading: samples.add,
      );
      sensors.setRunning('study-a');
      await sensors.settled;
      expect(samples.last.status, MotionStatus.error);
      expect(samples.last.distanceM, isNull);
      sensors.setRunning(null);
      await sensors.settled;
      sensors.setRunning('study-a');
      await sensors.settled;
      expect(samples.last.status, MotionStatus.running);
      await sensors.close(stop: true);
      location.dispose();
    },
  );
}
