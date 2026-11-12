import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:field_tms/actions/action_app.dart';
import 'package:field_tms/actions/action_journal.dart';
import 'package:field_tms/actions/action_journal_native.dart';
import 'package:field_tms/actions/action_recorder.dart';
import 'package:field_tms/actions/field_location.dart';
import 'package:field_tms/clock/capture_clock.dart';
import 'package:field_tms/motion/motion_tracker.dart';
import 'capture_test_pump.dart';

class TestClock implements CaptureClock {
  int now = 1000;
  int wallOffset = 0;
  @override
  int get monotonicMs => now;
  @override
  DateTime get wallTime => DateTime.fromMillisecondsSinceEpoch(
    1700000000000 + now + wallOffset,
    isUtc: true,
  );
}

class TestLocation extends FieldLocation {
  TestLocation() {
    bootId = 'boot-a';
  }
  @override
  Future<void> initialize() async {}
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> enable() async {}
  @override
  Map<String, dynamic> at(int monoMs) => {
    'latitude': 45.0,
    'longitude': -123.0,
    'accuracyM': 7.5,
    'fixUtc': '2023-11-14T22:13:20.000Z',
    'ageMs': monoMs - 900,
    'status': monoMs > 15900 ? 'stale' : 'fresh',
  };
}

class MemoryJournal implements ActionJournal {
  final rows = <Map<String, dynamic>>[];
  Completer<void>? barrier;
  bool fail = false;
  bool ambiguous = false;
  @override
  String get description => 'Live CSV on this device';
  @override
  Future<List<Map<String, dynamic>>> recent() async => List.of(rows);
  @override
  Future<void> append(Map<String, dynamic> event) async {
    await barrier?.future;
    if (fail && !ambiguous) throw const FileSystemException('Disk full');
    if (rows.isEmpty || rows.last['seq'] != event['seq']) rows.add(event);
    if (fail) throw const FileSystemException('Flush acknowledgement lost');
  }

  @override
  Stream<Uint8List> csv() async* {
    yield Uint8List.fromList(utf8.encode(actionCsvHeader));
    for (final row in rows) {
      yield Uint8List.fromList(utf8.encode(encodeActionEvent(row)));
    }
  }

  @override
  Future<void> close() async {}
}

class ReadinessLocation extends FieldLocation {
  ReadinessLocation({this.granted = true}) {
    bootId = 'boot-a';
  }
  bool granted;
  bool active = false;
  int starts = 0;
  int stops = 0;
  int prompts = 0;
  Completer<void>? startBarrier;
  Completer<void>? permissionBarrier;
  bool grantOnEnable = true;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> start() async {
    starts++;
    await startBarrier?.future;
    active = granted;
  }

  @override
  Future<void> stop() async {
    stops++;
    active = false;
  }

  @override
  Future<void> enable() async {
    if (!granted) prompts++;
    await permissionBarrier?.future;
    if (grantOnEnable) granted = true;
    await start();
  }

  @override
  Map<String, dynamic> at(int monoMs) => !granted
      ? {'status': 'permission_required'}
      : !active
      ? {'status': 'off'}
      : {
          'status': 'fresh',
          'latitude': 45.0,
          'longitude': -123.0,
          'accuracyM': 5.0,
          'fixUtc': '2023-11-14T22:13:20.900Z',
          'fixMonoMs': 900,
          'ageMs': monoMs - 900,
        };
}

class ImmediateMotion extends UnavailableMotionTracker {
  String? owner;
  @override
  Future<MotionReading> start({
    required String sessionId,
    double? stepLengthM,
  }) async {
    owner = sessionId;
    return _reading(MotionStatus.running);
  }

  @override
  Future<MotionReading> pause({required String sessionId}) async =>
      _reading(MotionStatus.paused);
  MotionReading _reading(MotionStatus status) => MotionReading(
    sessionId: owner,
    status: status,
    steps: 10,
    distanceM: 7,
    stepLengthM: .7,
    source: MotionSource.androidStepCounter,
    observedAtEpochMs: 1700000000000,
  );
}

ActionRecorder recorder(
  ActionJournal journal,
  TestClock clock, {
  TestLocation? location,
}) => ActionRecorder(
  journal,
  clock: clock,
  location: location ?? TestLocation(),
  motion: UnavailableMotionTracker(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'activity background responds before save and rolls back on failure',
    (tester) async {
      final journal = MemoryJournal();
      final c = recorder(journal, TestClock());
      await tester.pumpWidget(ActionCaptureApp(recorder: c));
      await pumpCaptureUi(tester);
      Color? background(String name) => tester
          .widget<OutlinedButton>(find.byKey(ValueKey('activity-$name')))
          .style!
          .backgroundColor!
          .resolve({});
      const selected = Color(0xFF2458D8);
      final idle = background('Planting');
      expect(selected, isNot(idle));
      expect(background('Walking'), idle);
      journal.barrier = Completer<void>();
      await tester.tap(find.text('Planting'));
      await tester.pump();
      expect(
        c.action,
        'Walking',
        reason: 'The durable activity has not changed yet.',
      );
      expect(background('Planting'), selected);
      expect(background('Walking'), idle);
      expect(find.text('Saving…'), findsNothing);
      await tester.tap(find.text('Walk out'));
      await tester.pump();
      expect(background('Walk out'), selected);
      expect(background('Planting'), idle);
      journal.barrier!.complete();
      await tester.pump();
      await tester.pump();
      expect(c.action, 'Walk out');
      expect(c.running, true);
      await tester.tap(find.text('Delay'));
      await tester.pump();
      expect(find.text('Personal'), findsOneWidget);
      expect(find.text('Operational'), findsOneWidget);
      expect(find.text('Mechanical'), findsOneWidget);
      expect(find.text('Administrative'), findsOneWidget);
      await tester.tap(find.text('Administrative'));
      await tester.pump();
      await tester.pump();
      final delay = background('Delay');
      expect(delay, isNot(idle));
      expect(c.action, 'Walk out');
      expect(c.delayRunning, true);
      expect(c.delayReason, 'Administrative');
      expect(background('Delay'), delay);
      journal.fail = true;
      await tester.tap(find.byKey(const ValueKey('activity-Preparation')));
      await tester.pump();
      await tester.pump();
      expect(c.action, 'Walk out');
      expect(c.delayRunning, true);
      expect(c.error, isNotNull);
      expect(background('Delay'), delay);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('activity-Delay')),
            )
            .style!
            .backgroundColor!
            .resolve({WidgetState.disabled}),
        delay,
      );
      expect(find.textContaining('Not saved'), findsOneWidget);
      expect(find.text('Retry save'), findsOneWidget);
      expect(find.byType(Scrollable), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  testWidgets(
    'a reused activity resets immediately and runs from the tap while storage is pending',
    (tester) async {
      final journal = MemoryJournal();
      final clock = TestClock();
      await tester.runAsync(() async {
        final seed = recorder(journal, clock);
        await seed.initialize();
        await seed.capture('Planting');
        clock.now = 6000;
        await seed.stop();
        await seed.close();
      });
      final c = recorder(journal, clock);
      await tester.pumpWidget(ActionCaptureApp(recorder: c));
      await pumpCaptureUi(tester);
      Finder plantingTime(String value) => find.descendant(
        of: find.byKey(const ValueKey('activity-Planting')),
        matching: find.text(value),
      );
      expect(plantingTime('00:00.00'), findsOneWidget);
      expect(plantingTime('Total 00:05.00'), findsOneWidget);
      journal.barrier = Completer<void>();
      clock.now = 10000;
      await tester.tap(find.byKey(const ValueKey('activity-Planting')));
      await tester.pump();
      expect(plantingTime('00:00.00'), findsOneWidget);
      expect(
        c.running,
        false,
        reason: 'Storage has not acknowledged Start yet.',
      );
      clock.now = 10200;
      await tester.pump(const Duration(milliseconds: 200));
      expect(plantingTime('00:00.20'), findsOneWidget);
      clock.now = 10500;
      await tester.tap(find.byKey(const ValueKey('activity-Walking')));
      await tester.pump();
      clock.now = 10600;
      await tester.tap(find.byKey(const ValueKey('activity-Planting')));
      await tester.pump();
      expect(plantingTime('00:00.00'), findsOneWidget);
      clock.now = 10800;
      await tester.pump(const Duration(milliseconds: 200));
      expect(plantingTime('00:00.20'), findsOneWidget);
      clock.now = 11000;
      journal.barrier!.complete();
      await pumpCaptureUi(tester);
      expect(c.action, 'Planting');
      expect(c.actionMs, 400);
      expect(c.totalMs, 6000);
      expect(plantingTime('00:00.40'), findsOneWidget);
      expect(journal.rows.skip(2).map((event) => event['boundary']['monoMs']), [
        10000,
        10500,
        10600,
      ]);
      expect(journal.rows[2]['kind'], 'start');
      expect(journal.rows[2]['state']['action'], 'Planting');
      await c.stop();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  testWidgets(
    'each activity shows its interval below its label and recent laps sit below total time',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final clock = TestClock();
      final c = recorder(MemoryJournal(), clock);
      await tester.pumpWidget(ActionCaptureApp(recorder: c));
      await pumpCaptureUi(tester);
      Finder inButton(String activity, String text) => find.descendant(
        of: find.byKey(ValueKey('activity-$activity')),
        matching: find.text(text),
      );
      for (final name in fieldActions) {
        expect(inButton(name, '00:00.00'), findsOneWidget);
        expect(
          tester.getCenter(inButton(name, '00:00.00')).dy,
          greaterThan(tester.getCenter(inButton(name, name)).dy),
        );
      }
      final walkingBounds = tester.getRect(
        find.byKey(const ValueKey('activity-Walking')),
      );
      final plantingBounds = tester.getRect(
        find.byKey(const ValueKey('activity-Planting')),
      );
      final preparationBounds = tester.getRect(
        find.byKey(const ValueKey('activity-Preparation')),
      );
      expect(
        walkingBounds.left - plantingBounds.right,
        greaterThanOrEqualTo(16),
      );
      expect(
        plantingBounds.top - preparationBounds.bottom,
        greaterThanOrEqualTo(16),
      );
      await c.startStop();
      clock.now = 2234;
      await tester.pump(const Duration(milliseconds: 200));
      expect(inButton('Walking', '00:01.23'), findsOneWidget);
      expect(inButton('Walking', 'Total 00:01.23'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('total-time'))).data,
        '00:01.23',
      );
      await c.select('Planting');
      await tester.pump();
      expect(inButton('Walking', '00:00.00'), findsOneWidget);
      expect(inButton('Walking', 'Total 00:01.23'), findsOneWidget);
      expect(inButton('Planting', '00:00.00'), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const ValueKey('recent-interval-1'))).top,
        greaterThan(
          tester.getRect(find.byKey(const ValueKey('total-time'))).bottom,
        ),
      );
      clock.now = 3603000;
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('total-time'))).data,
        '01:00:02.00',
      );
      expect(inButton('Planting', '01:00:00.76'), findsOneWidget);
      await c.setDelay(true);
      await tester.pump();
      expect(
        tester.getRect(find.byKey(const ValueKey('activity-Preparation'))),
        preparationBounds,
      );
      expect(find.text('Operational'), findsOneWidget);
      await c.chooseDelayReason('Operational');
      clock.now = 3604000;
      await tester.pump(const Duration(milliseconds: 200));
      expect(inButton('Planting', '01:00:01.76'), findsOneWidget);
      expect(inButton('Delay', '00:01.00'), findsOneWidget);
      expect(find.byType(Scrollable), findsNothing);
      expect(tester.takeException(), isNull);
      await c.startStop();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  test(
    'an existing GPS grant prepares the first Start without a prompt',
    () async {
      final journal = MemoryJournal();
      final location = ReadinessLocation();
      final clock = TestClock();
      final c = ActionRecorder(
        journal,
        clock: clock,
        location: location,
        motion: UnavailableMotionTracker(),
      );
      await c.initialize();
      await c.sensorsSettled;
      expect(location.active, true);
      expect(location.prompts, 0);
      expect(c.running, false);
      expect(journal.rows, isEmpty);
      await c.startStop();
      expect(journal.rows.single['boundary']['monoMs'], 1000);
      expect(journal.rows.single['boundary']['location']['status'], 'fresh');
      expect(journal.rows.single['boundary']['location']['ageMs'], 100);
      clock.now = 1234;
      await c.startStop();
      expect(c.totalMs, 234);
      await c.close();
    },
  );
  test(
    'GPS preparation never asks for permission or backfills captured boundaries',
    () async {
      final journal = MemoryJournal();
      final location = ReadinessLocation(granted: false)
        ..permissionBarrier = Completer<void>();
      final clock = TestClock();
      final c = ActionRecorder(
        journal,
        clock: clock,
        location: location,
        motion: UnavailableMotionTracker(),
      );
      await c.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(location.prompts, 0);
      await c.startStop();
      expect(
        journal.rows.single['boundary']['location']['status'],
        'permission_required',
      );
      location.permissionBarrier!.complete();
      await location.enable(); // Simulate granting access outside capture.
      await c.sensorsSettled;
      expect(location.prompts, 1);
      expect(
        journal.rows.single['boundary']['location']['status'],
        'permission_required',
      );
      clock.now = 1400;
      await c.select('Planting');
      expect(journal.rows.last['boundary']['location']['status'], 'fresh');
      expect(
        journal.rows.last['closed']['start']['location']['status'],
        'permission_required',
      );
      await c.startStop();
      await c.close();
    },
  );
  test(
    'denied automatic GPS never repeats prompts or blocks CSV capture',
    () async {
      final journal = MemoryJournal();
      final location = ReadinessLocation(granted: false)..grantOnEnable = false;
      final clock = TestClock();
      final c = ActionRecorder(
        journal,
        clock: clock,
        location: location,
        motion: UnavailableMotionTracker(),
      );
      await c.initialize();
      await c.sensorsSettled;
      expect(location.prompts, 0);
      c.setVisible(false);
      c.setVisible(true);
      await c.sensorsSettled;
      expect(location.prompts, 0);
      await c.capture('Planting');
      expect(
        journal.rows.single['boundary']['location']['status'],
        'permission_required',
      );
      clock.now += 60000;
      await c.stop();
      expect(journal.rows.last['closed']['durationMs'], 60000);
      expect(c.error, isNull);
      location.granted = true;
      c.setVisible(false);
      c.setVisible(true);
      await c.sensorsSettled;
      expect(location.active, true);
      expect(location.prompts, 0);
      await c.close();
    },
  );

  testWidgets('idle GPS preparation stops after a minute', (tester) async {
    final location = ReadinessLocation();
    final c = ActionRecorder(
      MemoryJournal(),
      clock: TestClock(),
      location: location,
      motion: UnavailableMotionTracker(),
    );
    await c.initialize();
    await c.sensorsSettled;
    await tester.pump(const Duration(seconds: 59));
    expect(location.active, true);
    await tester.pump(const Duration(seconds: 2));
    await c.sensorsSettled;
    expect(location.active, false);
    unawaited(c.close());
    await tester.pump();
  });
  testWidgets(
    'hiding idle capture releases GPS while running capture continues',
    (tester) async {
      final location = ReadinessLocation();
      final clock = TestClock();
      final c = ActionRecorder(
        MemoryJournal(),
        clock: clock,
        location: location,
        motion: UnavailableMotionTracker(),
      );
      await c.initialize();
      await c.sensorsSettled;
      c.setVisible(false);
      await c.sensorsSettled;
      expect(location.active, false);
      c.setVisible(true);
      await c.sensorsSettled;
      expect(location.active, true);
      await c.startStop();
      await c.sensorsSettled;
      final stopped = location.stops;
      c.setVisible(false);
      await tester.pump(const Duration(minutes: 2));
      await c.sensorsSettled;
      expect(location.stops, stopped);
      expect(location.active, true);
      clock.now = 2222;
      expect(c.totalMs, 1222);
      await c.startStop();
      await c.sensorsSettled;
      expect(location.active, false);
      unawaited(c.close());
      await tester.pump();
    },
  );
  testWidgets('late GPS preparation cannot keep a hidden idle screen active', (
    tester,
  ) async {
    final barrier = Completer<void>();
    final location = ReadinessLocation()..startBarrier = barrier;
    final c = ActionRecorder(
      MemoryJournal(),
      clock: TestClock(),
      location: location,
      motion: UnavailableMotionTracker(),
    );
    await c.initialize();
    c.setVisible(false);
    barrier.complete();
    await c.sensorsSettled;
    expect(location.active, false);
    await tester.pump(const Duration(minutes: 2));
    expect(location.active, false);
    unawaited(c.close());
    await tester.pump();
  });
  testWidgets('covered capture stays idle through app foreground changes', (
    tester,
  ) async {
    final location = ReadinessLocation();
    final c = ActionRecorder(
      MemoryJournal(),
      clock: TestClock(),
      location: location,
      motion: UnavailableMotionTracker(),
    );
    await tester.pumpWidget(ActionCaptureApp(recorder: c));
    await pumpCaptureUi(tester);
    await tester.tap(find.byTooltip('Study options'));
    await pumpCaptureUi(tester);
    await tester.tap(find.text('Saved records'));
    await pumpCaptureUi(tester);
    expect(location.active, false);
    final starts = location.starts;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpCaptureUi(tester);
    expect(location.starts, starts);
    await tester.tap(find.byTooltip('Back'));
    await pumpCaptureUi(tester);
    expect(location.active, true);
    expect(location.prompts, 0);
    await tester.pumpWidget(const SizedBox());
    await pumpCaptureUi(tester);
  });
  testWidgets('a pending Start cannot open records or settings', (
    tester,
  ) async {
    final journal = MemoryJournal();
    final c = recorder(journal, TestClock());
    await tester.pumpWidget(ActionCaptureApp(recorder: c));
    await pumpCaptureUi(tester);
    journal.barrier = Completer<void>();
    final start = c.startStop();
    await tester.pump();
    await tester.tap(find.byTooltip('Study options'));
    await pumpCaptureUi(tester);
    for (final value in ['settings', 'records']) {
      final item = tester.widget<PopupMenuItem<String>>(
        find.byWidgetPredicate(
          (widget) => widget is PopupMenuItem<String> && widget.value == value,
        ),
      );
      expect(item.enabled, false);
    }
    journal.barrier!.complete();
    await start;
    await c.startStop();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
  test(
    'queued new-study gestures never copy previous-study walking totals',
    () async {
      final journal = MemoryJournal();
      final clock = TestClock();
      final c = ActionRecorder(
        journal,
        clock: clock,
        location: TestLocation(),
        motion: ImmediateMotion(),
      );
      await c.initialize();
      await c.startStop();
      await c.sensorsSettled;
      clock.now = 2000;
      await c.startStop();
      await c.sensorsSettled;
      expect(c.walking.distanceM, 7);
      final newStudy = c.newStudy();
      clock.now = 2100;
      final selection = c.select('Planting');
      await Future.wait([newStudy, selection]);
      expect(
        journal.rows[journal.rows.length - 2]['boundary']['motion'],
        isNull,
      );
      expect(journal.rows.last['boundary']['motion'], isNull);
      expect(c.hasCurrentWalking, false);
      await c.close();
    },
  );

  test(
    'Resume excludes stopped time and complete interval milliseconds sum to the total',
    () async {
      final journal = MemoryJournal();
      final clock = TestClock();
      final c = recorder(journal, clock);
      await c.initialize();
      await c.startStop();
      clock.now = 1100;
      await c.select('Planting');
      clock.now = 1200;
      await c.startStop();
      clock.now = 100000;
      await c.startStop();
      clock.now = 100250;
      await c.startStop();
      expect(c.totalMs, 450);
      expect(c.count, 3);
      final durations = journal.rows
          .where((row) => row['closed'] != null)
          .map((row) => row['closed']['durationMs'] as int)
          .toList();
      expect(durations, [100, 100, 250]);
      await c.close();
    },
  );
  test(
    'continuous total, action intervals, duplicate taps, milliseconds and UTC fixes',
    () async {
      final journal = MemoryJournal();
      final clock = TestClock();
      final c = recorder(journal, clock);
      await c.initialize();
      await c.startStop();
      clock.now = 2123;
      await c.select('Planting');
      clock.wallOffset =
          -3600000; // Wall-clock correction cannot alter duration.
      clock.now = 2500;
      await c.select('Planting');
      clock.now = 4567;
      await c.select('Delay');
      clock.now = 4999;
      await c.startStop();
      expect(c.running, false);
      expect(c.totalMs, 3999);
      expect(c.count, 2);
      expect(c.delayCount, 1);
      final closed = journal.rows
          .where((e) => e['closed'] != null)
          .map((e) => e['closed'] as Map)
          .toList();
      expect(closed.map((e) => e['durationMs']), [1123, 2876]);
      expect(journal.rows.last['delayClosed']['durationMs'], 432);
      expect(journal.rows.last['delayClosed']['parentActivity'], 'Planting');
      expect(journal.rows[2]['kind'], 'repeat');
      for (final row in journal.rows) {
        final encoded = encodeActionEvent(row);
        expect(decodeActionEvent(encoded.trimRight()), row);
        expect((row['boundary'] as Map)['location']['accuracyM'], 7.5);
      }
      expect(encodeActionEvent(journal.rows[1]), contains('"1.123"'));
      await c.close();
    },
  );

  test(
    'gesture timestamps precede slow I/O and rapid switches preserve order',
    () async {
      final j = MemoryJournal();
      final clock = TestClock();
      final c = recorder(j, clock);
      await c.initialize();
      j.barrier = Completer<void>();
      final start = c.startStop();
      clock.now = 1100;
      final duplicateStart = c.startStop();
      clock.now = 1201;
      final first = c.select('Planting');
      clock.now = 1302;
      final second = c.select('Walking');
      clock.now = 8000;
      j.barrier!.complete();
      await Future.wait([start, duplicateStart, first, second]);
      expect(j.rows.map((e) => (e['boundary'] as Map)['monoMs']), [
        1000,
        1201,
        1302,
      ]);
      expect((j.rows[1]['closed'] as Map)['durationMs'], 201);
      expect((j.rows[2]['closed'] as Map)['durationMs'], 101);
      expect(c.totalMs, 7000);
      await c.close();
    },
  );

  test(
    'failed save keeps prior action; retry keeps original boundary and fences queued input',
    () async {
      final j = MemoryJournal();
      final clock = TestClock();
      final c = recorder(j, clock);
      await c.initialize();
      await c.startStop();
      j.fail = true;
      clock.now = 2001;
      final failed = c.select('Planting');
      clock.now = 3000;
      final queued = c.select('Delay');
      await Future.wait([failed, queued]);
      expect(c.action, 'Walking');
      expect(c.error, isNotNull);
      expect(c.running, true);
      j.fail = false;
      clock.now = 9000;
      await c.retrySave();
      expect(c.action, 'Planting');
      expect(c.error, isNull);
      expect((j.rows.last['boundary'] as Map)['monoMs'], 2001);
      expect(c.totalMs, 8000);
      expect(c.actionMs, 6999);
      await c.close();
    },
  );

  test('ambiguous acknowledgement retries idempotently', () async {
    final j = MemoryJournal();
    final clock = TestClock();
    final c = recorder(j, clock);
    await c.initialize();
    await c.startStop();
    j.fail = true;
    j.ambiguous = true;
    clock.now = 2345;
    await c.select('Planting');
    expect(c.action, 'Walking');
    expect(j.rows.length, 2);
    j.fail = false;
    await c.retrySave();
    expect(j.rows.length, 2);
    expect(c.action, 'Planting');
    await c.close();
  });

  test(
    'same-boot process recovery continues exact anchor, reboot marks unknown interval',
    () async {
      final j = MemoryJournal();
      final clock = TestClock();
      var c = recorder(j, clock);
      await c.initialize();
      await c.startStop();
      clock.now = 4321;
      await c.select('Planting');
      await c.close();
      clock.now = 9000;
      c = recorder(j, clock);
      await c.initialize();
      expect(c.running, true);
      expect(c.totalMs, 8000);
      expect(c.actionMs, 4679);
      await c.close();
      final otherBoot = TestLocation()..bootId = 'boot-b';
      clock.now = 100;
      c = recorder(j, clock, location: otherBoot);
      await c.initialize();
      expect(c.needsReview, true);
      expect(c.totalMs, 8000);
      await c.select('Walking');
      expect(c.action, 'Planting');
      await c.closeInterrupted();
      expect(c.running, false);
      expect((j.rows.last['closed'] as Map)['durationMs'], isNull);
      expect((j.rows.last['closed'] as Map)['interrupted'], true);
      await c.close();
    },
  );

  test(
    'native CSV reopens, repairs only torn tail, rejects complete corruption',
    () async {
      final dir = await Directory.systemTemp.createTemp('action-journal-test-');
      final file = File('${dir.path}/events.csv');
      final clock = TestClock();
      var journal = await FileActionJournal.open(file);
      final c = recorder(journal, clock);
      await c.initialize();
      await c.startStop();
      clock.now = 2123;
      await c.select('Planting');
      final original = await journal.csv().fold<BytesBuilder>(
        BytesBuilder(),
        (all, chunk) => all..add(chunk),
      );
      expect(utf8.decode(original.takeBytes()).split('\n').length, 4);
      await c.close();
      await file.writeAsString('"torn', mode: FileMode.append, flush: true);
      journal = await FileActionJournal.open(file);
      expect(journal.repairedBytes, 5);
      expect((await journal.recent()).length, 2);
      final last = (await journal.recent()).last;
      await journal.append(
        last,
      ); // Same immutable event cannot duplicate on retry.
      expect((await journal.recent()).length, 2);
      await journal.close();
      final bytes = await file.readAsString();
      final damaged = bytes.replaceFirst('"1.123"', '"9.123"');
      expect(damaged, isNot(bytes));
      await file.writeAsString(damaged, flush: true);
      await expectLater(FileActionJournal.open(file), throwsFormatException);
      expect(await file.readAsString(), damaged);
      await dir.delete(recursive: true);
    },
  );

  testWidgets(
    'activity taps start capture and Stop is available only inside the overflow menu',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final j = MemoryJournal();
      final clock = TestClock();
      final c = recorder(j, clock);
      await tester.pumpWidget(ActionCaptureApp(recorder: c));
      await pumpCaptureUi(tester);
      expect(find.text('Walking'), findsOneWidget);
      expect(find.text('Planting'), findsOneWidget);
      final walking = tester.getRect(
        find.byKey(const ValueKey('activity-Walking')),
      );
      final planting = tester.getRect(
        find.byKey(const ValueKey('activity-Planting')),
      );
      expect(walking.top, planting.top);
      expect(planting.left, lessThan(walking.left));
      expect(walking.width, greaterThan(150));
      expect(walking.height, greaterThanOrEqualTo(116));
      await tester.tap(find.byKey(const ValueKey('activity-Walking')));
      await tester.pump();
      await tester.pump();
      expect(find.text('Stop'), findsNothing);
      expect(c.running, true);
      clock.now = 2222;
      await tester.tap(find.text('Planting'));
      await tester.pump();
      await tester.pump();
      expect(c.action, 'Planting');
      expect(c.totalMs, 1222);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Study options'));
      await pumpCaptureUi(tester);
      expect(
        c.running,
        true,
        reason: 'Opening the menu must not stop capture.',
      );
      expect(find.text('Stop'), findsOneWidget);
      clock.now = 3333;
      await tester.tap(find.byKey(const ValueKey('capture-stop')));
      await pumpCaptureUi(tester);
      expect(c.running, false);
      expect(j.rows.last['closed']['durationMs'], 1111);
      expect(find.text('Stop'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'Walk out permits Planting or Preparation and a new delay increments its parent immediately',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final j = MemoryJournal();
      final clock = TestClock();
      final c = recorder(j, clock);
      await tester.pumpWidget(ActionCaptureApp(recorder: c));
      await pumpCaptureUi(tester);
      bool enabled(String name) =>
          tester
              .widget<OutlinedButton>(find.byKey(ValueKey('activity-$name')))
              .onPressed !=
          null;
      expect(enabled('Preparation'), false);
      await tester.tap(find.byKey(const ValueKey('activity-Planting')));
      await pumpCaptureUi(tester);
      clock.now = 2000;
      j.barrier = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('activity-Delay')));
      await tester.pump();
      Finder count(String name, int value) => find.descendant(
        of: find.byKey(ValueKey('activity-$name')),
        matching: find.text('Delays: $value'),
      );
      expect(count('Planting', 1), findsOneWidget);
      expect(c.activityDelayCount, 0);
      j.barrier!.complete();
      await pumpCaptureUi(tester);
      await tester.tap(find.text('Administrative'));
      await pumpCaptureUi(tester);
      await tester.tap(find.byKey(const ValueKey('activity-Delay')));
      await pumpCaptureUi(tester);
      expect(count('Planting', 1), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('activity-Delay')));
      await pumpCaptureUi(tester);
      expect(count('Planting', 2), findsOneWidget);
      await tester.tap(find.text('Personal'));
      await pumpCaptureUi(tester);
      clock.now = 3000;
      await tester.tap(find.byKey(const ValueKey('activity-Walking')));
      await pumpCaptureUi(tester);
      expect(find.text('Cycle 1'), findsOneWidget);
      expect(find.text('· Cycle 1').evaluate().length, greaterThanOrEqualTo(2));
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('current-cycle'))).data,
        'Cycle 1',
      );
      expect(count('Walking', 1), findsNothing);
      clock.now = 4000;
      await tester.tap(find.byKey(const ValueKey('activity-Planting')));
      await pumpCaptureUi(tester);
      expect(c.cycle, 2);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('current-cycle'))).data,
        'Cycle 2',
      );
      expect(count('Planting', 2), findsNothing);
      expect(find.text('· Cycle 1').evaluate().length, greaterThanOrEqualTo(1));
      await tester.tap(find.byKey(const ValueKey('activity-Walk out')));
      await pumpCaptureUi(tester);
      expect(enabled('Preparation'), true);
      expect(enabled('Walking'), false);
      expect(enabled('Planting'), true);
      expect(find.text('Cycle 2'), findsOneWidget);
      expect(find.text('· Cycle 2').evaluate().length, greaterThanOrEqualTo(1));
      await tester.tap(find.byKey(const ValueKey('activity-Planting')));
      await pumpCaptureUi(tester);
      expect(c.action, 'Planting');
      expect(c.cycle, 3);
      await tester.tap(find.byKey(const ValueKey('activity-Walk out')));
      await pumpCaptureUi(tester);
      await tester.tap(find.byKey(const ValueKey('activity-Preparation')));
      await pumpCaptureUi(tester);
      expect(enabled('Preparation'), false);
      expect(enabled('Walking'), true);
      expect(enabled('Planting'), true);
      await c.stop();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'capture never scrolls in portrait, landscape, large text or recovery',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final size in [
        const Size(320, 568),
        const Size(390, 844),
        const Size(568, 320),
        const Size(844, 390),
      ]) {
        for (final scale in [1.0, 2.0]) {
          tester.view.physicalSize = size;
          tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          final journal = MemoryJournal();
          final clock = TestClock();
          final c = recorder(journal, clock);
          void assertFits() {
            expect(find.byType(Scrollable), findsNothing);
            if (c.delayRunning) {
              expect(
                find.byKey(const ValueKey('recent-interval-current-delay')),
                findsOneWidget,
              );
              expect(
                find.byKey(const ValueKey('recent-interval-current-activity')),
                findsOneWidget,
              );
            }
            expect(find.textContaining('Choose an activity'), findsNothing);
            final time = tester.getRect(
              find.byKey(const ValueKey('total-time')),
            );
            final cycle = tester.getRect(
              find.byKey(const ValueKey('current-cycle')),
            );
            expect(
              time.center.dx,
              closeTo(tester.getCenter(find.text('Total time')).dx, 1),
              reason: 'Cycle must not move the clock off center.',
            );
            if (size.height > size.width) {
              expect(time.center.dx, closeTo(size.width / 2, 1));
            }
            expect(cycle.center.dx, greaterThan(time.center.dx));
            expect(cycle.overlaps(time), false);
            for (final name in [
              'Walking',
              'Planting',
              'Preparation',
              'Walk out',
              'Delay',
            ]) {
              final target = find.byKey(ValueKey('activity-$name'));
              if (target.evaluate().isEmpty) {
                expect(
                  find.text('Administrative').evaluate().isNotEmpty ||
                      find.text('Retry save').evaluate().isNotEmpty ||
                      find.text('Close activity').evaluate().isNotEmpty,
                  true,
                );
                continue;
              }
              final bounds = tester.getRect(target);
              expect(
                bounds.top,
                greaterThanOrEqualTo(size.height / 2),
                reason: '$size at $scale, $name',
              );
              expect(
                bounds.bottom,
                lessThanOrEqualTo(size.height),
                reason: '$size at $scale, $name',
              );
              expect(bounds.left, greaterThanOrEqualTo(0));
              expect(bounds.right, lessThanOrEqualTo(size.width));
              if (name == 'Delay' &&
                  find
                      .byKey(const ValueKey('delay-reason-picker'))
                      .evaluate()
                      .isNotEmpty) {
                continue;
              }
              expect(
                (tester
                            .getCenter(
                              find.descendant(
                                of: find.byKey(ValueKey('activity-$name')),
                                matching: name == 'Delay'
                                    ? find.textContaining('Delay')
                                    : find.text(name),
                              ),
                            )
                            .dx -
                        bounds.center.dx)
                    .abs(),
                lessThan(1),
              );
            }
            expect(find.byKey(const ValueKey('capture-primary')), findsNothing);
            for (final label in [
              'Stopped',
              'Saved',
              'Recording',
              'Saving…',
              'Walking unavailable',
              'GPS unavailable',
            ]) {
              expect(find.text(label), findsNothing);
            }
            expect(find.textContaining(' activities'), findsNothing);
            expect(tester.takeException(), isNull, reason: '$size at $scale');
          }

          await tester.pumpWidget(ActionCaptureApp(recorder: c));
          await pumpCaptureUi(tester);
          assertFits();
          await c.startStop();
          await tester.pump();
          assertFits();
          await c.setDelay(true);
          await tester.pump();
          assertFits();
          for (final reason in delayReasons) {
            final bounds = tester.getRect(
              find.byKey(ValueKey('delay-reason-$reason')),
            );
            expect(bounds.top, greaterThanOrEqualTo(0));
            expect(bounds.bottom, lessThanOrEqualTo(size.height - 24));
            expect(bounds.height, greaterThanOrEqualTo(44));
          }
          await c.chooseDelayReason('Administrative');
          await tester.pump();
          assertFits();
          journal.fail = true;
          await tester.tap(find.text('Planting'));
          await tester.pump();
          await tester.pump();
          expect(find.text('Retry save'), findsOneWidget);
          assertFits();
          journal.fail = false;
          await c.retrySave();
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          clock.now = 100;
          final rebooted = recorder(
            journal,
            clock,
            location: TestLocation()..bootId = 'boot-b',
          );
          await tester.pumpWidget(ActionCaptureApp(recorder: rebooted));
          await pumpCaptureUi(tester);
          expect(find.text('Close activity'), findsOneWidget);
          assertFits();
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        }
      }
    },
  );
}
