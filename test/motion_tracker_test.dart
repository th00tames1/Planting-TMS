import 'dart:async';

import 'package:field_tms/motion/motion_tracker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel(NativeMotionTracker.methodChannelName);
  const eventMethods = MethodChannel(NativeMotionTracker.eventChannelName);
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(eventMethods, null);
  });

  test('native readings round-trip without deriving or rounding distance', () {
    final raw = _map();
    final reading = MotionReading.fromMap(raw);
    expect(reading.status, MotionStatus.running);
    expect(reading.source, MotionSource.androidStepCounter);
    expect(reading.steps, 12);
    expect(reading.distanceM, 8.4);
    expect(reading.toMap(), raw);
    expect(() => reading.toMap()['steps'] = 99, throwsUnsupportedError);

    final ios = MotionReading.fromMap({
      ...raw,
      'source': 'ios_pedometer',
      'stepLengthM': null,
      'distanceM': 8.123456789,
    });
    expect(ios.source, MotionSource.iosPedometer);
    expect(ios.toMap()['distanceM'], 8.123456789);
    final zero = MotionReading.fromMap({...raw, 'steps': 0, 'distanceM': 0});
    expect(zero.distanceM, 0.0);
  });

  test('corrupt snapshots fail rather than clamping into measurements', () {
    final corruptions = <Map<String, dynamic>>[
      {'steps': -1},
      {'steps': 1.2},
      {'steps': '12'},
      {'distanceM': -0.1},
      {'distanceM': double.nan},
      {'distanceM': double.infinity},
      {'distanceM': '8.4'},
      {'stepLengthM': -1},
      {'stepLengthM': 0},
      {'stepLengthM': double.infinity},
      {'observedAtEpochMs': -1},
      {'observedAtEpochMs': 1.2},
      {'sessionId': '  '},
      {'sessionId': 123},
      {'source': 'gps'},
      {'source': 'unavailable'},
      {'status': 'unknown'},
      {'status': 'permissionDenied'},
      {'status': 'error'},
      {'estimated': false},
      {'gap': null},
      {'message': 123},
    ];
    for (final corruption in corruptions) {
      expect(
        () => MotionReading.fromMap({..._map(), ...corruption}),
        throwsFormatException,
        reason: corruption.keys.join(', '),
      );
    }
    expect(
      () => MotionReading.fromMap({'status': 'paused'}),
      throwsFormatException,
    );
  });

  test('ordering metadata is optional together and portable when present', () {
    final ordered = _orderedMap(7);
    expect(MotionReading.fromMap(ordered).toMap(), ordered);
    final maximum = MotionReading.fromMap(
      _orderedMap(MotionReading.maxObservationSequence),
    );
    expect(maximum.observationSequence, 9007199254740991);
    for (final invalid in <Map<String, Object?>>[
      {'observationEpoch': 'owner-a'},
      {'observationSequence': 1},
      {'observationEpoch': '', 'observationSequence': 1},
      {'observationEpoch': ' owner-a ', 'observationSequence': 1},
      {'observationEpoch': 'owner-a', 'observationSequence': 0},
      {'observationEpoch': 'owner-a', 'observationSequence': -1},
      {'observationEpoch': 'owner-a', 'observationSequence': 1.0},
      {
        'observationEpoch': 'owner-a',
        'observationSequence': MotionReading.maxObservationSequence + 1,
      },
    ]) {
      expect(
        () => MotionReading.fromMap({..._map(), ...invalid}),
        throwsFormatException,
        reason: invalid.toString(),
      );
    }
  });

  test('unavailable states always have null distance', () async {
    const initial = MotionReading.unavailable();
    expect(initial.distanceM, isNull);
    expect(initial.source, MotionSource.unavailable);
    expect(initial.observedAtEpochMs, 0);
    final tracker = UnavailableMotionTracker(nowEpochMs: () => 1234);
    addTearDown(tracker.dispose);
    final readings = [
      await tracker.read(),
      await tracker.start(sessionId: 'session', stepLengthM: 0.75),
      await tracker.setStepLength(stepLengthM: 0.8),
      await tracker.pause(sessionId: 'session'),
      await tracker.setStepLength(),
      await tracker.read(),
    ];
    for (final reading in readings) {
      expect(reading.status, MotionStatus.unavailable);
      expect(reading.distanceM, isNull);
      expect(reading.toMap()['distanceM'], isNull);
      expect(reading.estimated, isTrue);
      expect(reading.toMap().containsKey('demo'), isFalse);
    }
    expect(readings[1].sessionId, 'session');
    expect(readings[1].stepLengthM, 0.75);
    expect(readings.last.stepLengthM, isNull);
  });

  test('factory keeps web and desktop explicitly unavailable', () async {
    final web = createDefaultMotionTracker(
      isWeb: true,
      platform: TargetPlatform.android,
    );
    final desktop = createDefaultMotionTracker(
      isWeb: false,
      platform: TargetPlatform.windows,
    );
    final android = createDefaultMotionTracker(
      isWeb: false,
      platform: TargetPlatform.android,
    );
    final ios = createDefaultMotionTracker(
      isWeb: false,
      platform: TargetPlatform.iOS,
    );
    for (final tracker in [web, desktop, android, ios]) {
      addTearDown(tracker.dispose);
    }
    expect(web, isA<UnavailableMotionTracker>());
    expect(desktop, isA<UnavailableMotionTracker>());
    expect(android, isA<NativeMotionTracker>());
    expect(ios, isA<NativeMotionTracker>());
    expect((await web.start(sessionId: 'web')).distanceM, isNull);
    expect((await desktop.read()).distanceM, isNull);
  });

  test(
    'methods use the exact channel and nullable calibration contract',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        return _map(status: 'paused');
      });
      final tracker = NativeMotionTracker();
      addTearDown(tracker.dispose);
      expect((await tracker.read()).status, MotionStatus.paused);
      await tracker.start(sessionId: 'session-1', stepLengthM: 0.7);
      await tracker.pause(sessionId: 'session-1');
      await tracker.setStepLength(stepLengthM: 0.8);
      await tracker.setStepLength();
      expect(calls.map((call) => call.method), [
        'read',
        'start',
        'pause',
        'setStepLength',
        'setStepLength',
      ]);
      expect(calls.first.arguments, isNull);
      expect(calls[1].arguments, {
        'sessionId': 'session-1',
        'stepLengthM': 0.7,
      });
      expect(calls[2].arguments, {'sessionId': 'session-1'});
      expect(calls[3].arguments, {'stepLengthM': 0.8});
      expect(calls[4].arguments, {'stepLengthM': null});
      expect(() => tracker.start(sessionId: ' '), throwsArgumentError);
      expect(
        () => tracker.setStepLength(stepLengthM: double.nan),
        throwsArgumentError,
      );
      expect(calls.length, 5);
    },
  );

  test(
    'missing native distance stays null even with steps or calibration',
    () async {
      messenger.setMockMethodCallHandler(methods, (call) async {
        return {
          ..._map(),
          'steps': 1200,
          'distanceM': null,
          'stepLengthM': 0.7,
        };
      });
      final tracker = NativeMotionTracker();
      addTearDown(tracker.dispose);
      final reading = await tracker.read();
      expect(reading.steps, 1200);
      expect(reading.distanceM, isNull);
      expect(reading.toMap()['distanceM'], isNull);
    },
  );

  test(
    'permission and missing sensor errors become honest availability',
    () async {
      final tracker = NativeMotionTracker(nowEpochMs: () => 1234);
      addTearDown(tracker.dispose);
      messenger.setMockMethodCallHandler(methods, (_) async {
        throw PlatformException(
          code: 'permission_denied',
          message: 'Native text',
        );
      });
      final denied = await tracker.start(sessionId: 'session-1');
      expect(denied.status, MotionStatus.permissionDenied);
      expect(denied.sessionId, 'session-1');
      expect(denied.distanceM, isNull);
      expect(denied.message, contains('permission'));
      expect(denied.message, isNot('Native text'));

      messenger.setMockMethodCallHandler(methods, (_) async {
        throw PlatformException(code: 'sensor_unavailable');
      });
      final unavailable = await tracker.read();
      expect(unavailable.status, MotionStatus.unavailable);
      expect(unavailable.distanceM, isNull);
      expect(unavailable.observedAtEpochMs, 1234);

      messenger.setMockMethodCallHandler(methods, null);
      final missingPlugin = await tracker.read();
      expect(missingPlugin.status, MotionStatus.unavailable);
      expect(missingPlugin.distanceM, isNull);
    },
  );

  test(
    'malformed and generic errors cannot masquerade as zero distance',
    () async {
      final tracker = NativeMotionTracker();
      addTearDown(tracker.dispose);
      for (final malformed in <Object?>[
        null,
        'invalid',
        {..._map(), 'distanceM': double.infinity},
      ]) {
        messenger.setMockMethodCallHandler(methods, (_) async => malformed);
        final reading = await tracker.read();
        expect(reading.status, MotionStatus.error);
        expect(reading.distanceM, isNull);
        expect(reading.message, contains('invalid'));
      }
      messenger.setMockMethodCallHandler(methods, (_) async {
        throw PlatformException(code: 'native_error');
      });
      expect((await tracker.read()).distanceM, isNull);
      expect((await tracker.read()).status, MotionStatus.error);
    },
  );

  test(
    'events decode data and recover after errors without uncaught errors',
    () async {
      final eventCalls = <String>[];
      messenger.setMockMethodCallHandler(eventMethods, (call) async {
        eventCalls.add(call.method);
        return null;
      });
      final tracker = NativeMotionTracker(nowEpochMs: () => 1234);
      final received = <MotionReading>[];
      final streamErrors = <Object>[];
      final subscription = tracker.readings.listen(
        received.add,
        onError: streamErrors.add,
      );
      await Future<void>.delayed(Duration.zero);
      await _event(codec.encodeSuccessEnvelope(_map()));
      await _event(codec.encodeErrorEnvelope(code: 'permission_denied'));
      await _event(codec.encodeSuccessEnvelope({..._map(), 'steps': -1}));
      await _event(
        codec.encodeSuccessEnvelope({
          ..._map(),
          'steps': 20,
          'distanceM': 14.0,
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(received.map((reading) => reading.status), [
        MotionStatus.running,
        MotionStatus.permissionDenied,
        MotionStatus.error,
        MotionStatus.running,
      ]);
      expect(received[1].distanceM, isNull);
      expect(received[1].gap, isTrue);
      expect(received[2].distanceM, isNull);
      expect(received.last.distanceM, 14);
      expect(streamErrors, isEmpty);
      await subscription.cancel();
      await tracker.dispose();
      expect(eventCalls, ['listen', 'cancel']);
    },
  );

  test('missing event plugin is data, not a FlutterError', () async {
    final tracker = NativeMotionTracker();
    addTearDown(tracker.dispose);
    final reading = await tracker.readings.first;
    expect(reading.status, MotionStatus.unavailable);
    expect(reading.distanceM, isNull);
    await tracker.dispose();
    final reader = NativeMotionTracker();
    addTearDown(reader.dispose);
    expect((await reader.read()).status, MotionStatus.unavailable);
  });

  test(
    'events use serial order through wall rollback and counter reset',
    () async {
      messenger.setMockMethodCallHandler(eventMethods, (_) async => null);
      final tracker = NativeMotionTracker();
      final received = <MotionReading>[];
      final subscription = tracker.readings.listen(received.add);
      addTearDown(() async {
        await subscription.cancel();
        await tracker.dispose();
      });
      await Future<void>.delayed(Duration.zero);
      for (final raw in [
        {..._orderedMap(5), 'steps': 10, 'observedAtEpochMs': 10000},
        {..._orderedMap(4), 'steps': 10000, 'observedAtEpochMs': 20000},
        {..._orderedMap(6), 'steps': 2, 'observedAtEpochMs': 5000},
        {..._orderedMap(5), 'steps': 10000, 'observedAtEpochMs': 20000},
        {..._orderedMap(7), 'steps': 5, 'observedAtEpochMs': 5001},
      ]) {
        await _event(codec.encodeSuccessEnvelope(raw));
      }
      await Future<void>.delayed(Duration.zero);
      expect(received.map((reading) => reading.steps), [10, 2, 5]);
      expect(received.map((reading) => reading.observedAtEpochMs), [
        10000,
        5000,
        5001,
      ]);
    },
  );

  test(
    'late method reply cannot replace newer state from another study',
    () async {
      final delayed = Completer<Map<String, dynamic>>();
      var calls = 0;
      messenger.setMockMethodCallHandler(methods, (_) async {
        calls++;
        if (calls == 1) return delayed.future;
        return {..._orderedMap(20), 'sessionId': 'other-study', 'steps': 3};
      });
      final tracker = NativeMotionTracker();
      addTearDown(tracker.dispose);
      final oldReply = tracker.read();
      final current = await tracker.read();
      expect(current.sessionId, 'other-study');
      delayed.complete({..._orderedMap(10), 'steps': 10000});
      final resolvedOldReply = await oldReply;
      expect(resolvedOldReply.sessionId, 'other-study');
      expect(resolvedOldReply.steps, 3);
      expect(resolvedOldReply.observationSequence, 20);
    },
  );

  test(
    'newer event fences a delayed method response and equal event',
    () async {
      final delayed = Completer<Map<String, dynamic>>();
      messenger.setMockMethodCallHandler(methods, (_) => delayed.future);
      messenger.setMockMethodCallHandler(eventMethods, (_) async => null);
      final tracker = NativeMotionTracker();
      final received = <MotionReading>[];
      final subscription = tracker.readings.listen(received.add);
      addTearDown(() async {
        await subscription.cancel();
        await tracker.dispose();
      });
      await Future<void>.delayed(Duration.zero);
      final pending = tracker.read();
      await _event(
        codec.encodeSuccessEnvelope({..._orderedMap(9), 'steps': 9}),
      );
      delayed.complete({..._orderedMap(8), 'steps': 10000});
      expect((await pending).steps, 9);
      await _event(
        codec.encodeSuccessEnvelope({..._orderedMap(9), 'steps': 10000}),
      );
      await Future<void>.delayed(Duration.zero);
      expect(received.map((reading) => reading.steps), [9]);
    },
  );

  test(
    'paired transport rejects legacy downgrade without losing its fence',
    () async {
      var reply = _orderedMap(2);
      messenger.setMockMethodCallHandler(methods, (_) async => reply);
      final tracker = NativeMotionTracker();
      addTearDown(tracker.dispose);
      expect((await tracker.read()).observationSequence, 2);
      reply = _map();
      expect((await tracker.read()).status, MotionStatus.error);
      reply = {..._orderedMap(3), 'steps': 13};
      expect((await tracker.read()).steps, 13);
    },
  );

  test(
    'unexpected native owner is latched until a fresh tracker reconnects',
    () async {
      var reply = _orderedMap(2);
      messenger.setMockMethodCallHandler(methods, (_) async => reply);
      final tracker = NativeMotionTracker();
      addTearDown(tracker.dispose);
      await tracker.read();
      reply = {..._orderedMap(1), 'observationEpoch': 'owner-b'};
      final changed = await tracker.read();
      expect(changed.status, MotionStatus.error);
      expect(changed.distanceM, isNull);
      expect(changed.gap, isTrue);
      expect(changed.message, contains('Close and reopen'));
      reply = _orderedMap(3);
      expect((await tracker.read()).status, MotionStatus.error);

      final reconnected = NativeMotionTracker();
      addTearDown(reconnected.dispose);
      reply = {..._orderedMap(1), 'observationEpoch': 'owner-b'};
      expect((await reconnected.read()).observationEpoch, 'owner-b');
    },
  );

  test('disposal tolerates a disconnected native event stream', () async {
    messenger.setMockMethodCallHandler(eventMethods, (call) async {
      if (call.method == 'cancel') throw MissingPluginException();
      return null;
    });
    final tracker = NativeMotionTracker();
    final subscription = tracker.readings.listen((_) {});
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();
    await tracker.dispose();
    await tracker.dispose();
    await expectLater(tracker.read(), throwsStateError);
  });
}

Map<String, dynamic> _map({String status = 'running'}) => {
  'sessionId': 'session-1',
  'status': status,
  'steps': 12,
  'distanceM': 8.4,
  'stepLengthM': 0.7,
  'source': 'android_step_counter',
  'estimated': true,
  'observedAtEpochMs': 1800000000000,
  'gap': false,
  'message': null,
};

Map<String, dynamic> _orderedMap(int sequence) => {
  ..._map(),
  'observationEpoch': 'owner-a',
  'observationSequence': sequence,
};

Future<void> _event(ByteData? envelope) {
  final delivered = Completer<void>();
  ServicesBinding.instance.channelBuffers.push(
    NativeMotionTracker.eventChannelName,
    envelope,
    (_) => delivered.complete(),
  );
  return delivered.future;
}
