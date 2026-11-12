import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:field_tms/actions/field_location.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('field_tms/location');
  const events = MethodChannel('field_tms/location_events');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late FieldLocation location;
  Completer<Map<String, dynamic>>? slowStart;
  Future<void> publish(Map<String, dynamic> value) async {
    final done = Completer<void>();
    // Test messenger injects the exact platform-channel envelope.
    messenger.handlePlatformMessage(
      events.name,
      codec.encodeSuccessEnvelope(value),
      (_) => done.complete(),
    );
    await done.future;
  }

  setUp(() async {
    slowStart = null;
    messenger.setMockMethodCallHandler(
      methods,
      (call) async => switch (call.method) {
        'clockInfo' => {'bootId': 'device-boot-a'},
        'start' =>
          slowStart?.future ??
              {'status': 'waiting', 'publisher': 'gps-a', 'serial': 0},
        _ => {'status': 'off', 'publisher': 'gps-a', 'serial': 99},
      },
    );
    messenger.setMockMethodCallHandler(events, (_) async => null);
    location = FieldLocation();
    await location.initialize();
  });
  tearDown(() {
    location.dispose();
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  test(
    'records actual age, stale fixes and mismatched clocks explicitly',
    () async {
      await publish({
        'status': 'fresh',
        'latitude': 45.1,
        'longitude': -122.9,
        'accuracyM': 8.5,
        'fixMonoMs': 9000,
        'fixUtc': '2026-10-27T12:00:00.000Z',
        'publisher': 'gps-a',
        'serial': 1,
      });
      expect(location.bootId, 'device-boot-a');
      expect(location.at(10000)['ageMs'], 1000);
      expect(location.at(10000)['status'], 'fresh');
      expect(location.at(25001)['status'], 'stale');
      expect(location.at(8000)['status'], 'clock_mismatch');
      expect(location.at(25001)['fixUtc'], '2026-10-27T12:00:00.000Z');
    },
  );
  test('late method responses cannot replace newer GPS events', () async {
    slowStart = Completer<Map<String, dynamic>>();
    final request = location.start();
    await publish({
      'status': 'fresh',
      'latitude': 45.1,
      'longitude': -122.9,
      'accuracyM': 8.5,
      'fixMonoMs': 9000,
      'fixUtc': '2026-10-27T12:00:00.000Z',
      'publisher': 'gps-a',
      'serial': 2,
    });
    slowStart!.complete({
      'status': 'waiting',
      'publisher': 'gps-a',
      'serial': 1,
    });
    await request;
    expect(location.at(10000)['latitude'], 45.1);
    expect(location.at(10000)['status'], 'fresh');
  });
  test(
    'invalid, denied and simulated readings cannot appear as measured GPS',
    () async {
      await publish({
        'status': 'fresh',
        'latitude': 95,
        'longitude': -122.9,
        'accuracyM': 8.5,
        'publisher': 'gps-a',
        'serial': 1,
      });
      expect(location.at(10000), {'status': 'invalid'});
      await publish({'status': 'denied', 'publisher': 'gps-a', 'serial': 2});
      expect(location.at(10000)['latitude'], isNull);
      expect(location.at(10000)['status'], 'denied');
      await publish({
        'status': 'fresh',
        'latitude': 45.1,
        'longitude': -122.9,
        'accuracyM': 8.5,
        'mock': true,
        'fixMonoMs': 9000,
        'fixUtc': '2026-10-27T12:00:00.000Z',
        'publisher': 'gps-a',
        'serial': 3,
      });
      expect(location.at(30000)['status'], 'simulated');
    },
  );
}
