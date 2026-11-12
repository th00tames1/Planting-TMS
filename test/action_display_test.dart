import 'dart:async';

import 'package:field_tms/actions/action_app.dart';
import 'package:field_tms/actions/action_recorder.dart';
import 'package:field_tms/motion/motion_tracker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'action_capture_test.dart' show MemoryJournal, TestClock, TestLocation;
import 'capture_test_pump.dart';

class DisplayRecorder extends ActionRecorder {
  DisplayRecorder(super.journal, TestClock clock)
    : super(
        clock: clock,
        location: TestLocation(),
        motion: UnavailableMotionTracker(),
      );
  int recentReads = 0;
  @override
  List<Map<String, dynamic>> get recentIntervals {
    recentReads++;
    return super.recentIntervals;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'display follows 60 frames without history rebuilds or journal writes',
    (tester) async {
      final journal = MemoryJournal();
      final clock = TestClock();
      final c = DisplayRecorder(journal, clock);
      await tester.pumpWidget(ActionCaptureApp(recorder: c));
      await pumpCaptureUi(tester);
      await c.capture('Planting');
      clock.now = 1100;
      await c.capture('Walking');
      clock.now = 1200;
      await c.capture('Planting');
      await c.setDelay(true);
      await c.chooseDelayReason('Personal');
      await pumpCaptureUi(tester);
      final writes = journal.rows.length;
      final ticks = c.ticks.value;
      final sensors = c.sensorTicks.value;
      final inactive = tester.widget(
        find.byKey(const ValueKey('activity-total-Walking')),
      );
      c.recentReads = 0;
      for (var i = 0; i < 60; i++) {
        clock.now += 16;
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(c.ticks.value - ticks, 60);
      expect(c.sensorTicks.value, sensors);
      expect(journal.rows.length, writes);
      expect(c.recentReads, 0);
      expect(
        identical(
          inactive,
          tester.widget(find.byKey(const ValueKey('activity-total-Walking'))),
        ),
        true,
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('total-time'))).data,
        '00:01.16',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('activity-time-Planting')))
            .data,
        '00:00.96',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('activity-total-Planting')))
            .data,
        'Total 00:01.06',
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('activity-Delay')),
          matching: find.text('00:00.96'),
        ),
        findsOneWidget,
      );
      await c.stop();
      expect(journal.rows.last['closed']['durationMs'], 960);
      expect(journal.rows.last['delayClosed']['durationMs'], 960);
      expect(c.totalMs, 1160);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('sub-centisecond frames do not rebuild identical readouts', (
    tester,
  ) async {
    final clock = TestClock();
    final c = DisplayRecorder(MemoryJournal(), clock);
    await tester.pumpWidget(ActionCaptureApp(recorder: c));
    await pumpCaptureUi(tester);
    await c.capture('Planting');
    await pumpCaptureUi(tester);
    final ticks = c.ticks.value;
    for (var i = 0; i < 9; i++) {
      clock.now++;
      await tester.pump(const Duration(milliseconds: 4));
    }
    expect(c.ticks.value, ticks);
    clock.now++;
    await tester.pump(const Duration(milliseconds: 4));
    expect(c.ticks.value, ticks + 1);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('total-time'))).data,
      '00:00.01',
    );
    await c.stop();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'hidden display stops frame signals and resumes from the continuous clock',
    (tester) async {
      final journal = MemoryJournal();
      final clock = TestClock();
      final c = DisplayRecorder(journal, clock);
      await tester.pumpWidget(ActionCaptureApp(recorder: c));
      await pumpCaptureUi(tester);
      await c.capture('Planting');
      await pumpCaptureUi(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      final ticks = c.ticks.value;
      clock.now += 3000;
      await tester.pump(const Duration(seconds: 3));
      expect(c.ticks.value, ticks);
      expect(journal.rows.length, 1);
      expect(c.totalMs, 3000);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpCaptureUi(tester);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('total-time'))).data,
        '00:03.00',
      );
      await c.stop();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    '120 Hz frames are capped while measurement and saved boundaries stay exact',
    (tester) async {
      final clock = TestClock()..now = 1007;
      final journal = MemoryJournal();
      final c = DisplayRecorder(journal, clock);
      await tester.pumpWidget(ActionCaptureApp(recorder: c));
      await pumpCaptureUi(tester);
      await c.capture('Planting');
      await pumpCaptureUi(tester);
      final ticks = c.ticks.value;
      final writes = journal.rows.length;
      for (var i = 0; i < 120; i++) {
        clock.now += 8;
        await tester.pump(const Duration(milliseconds: 8));
      }
      expect(c.ticks.value - ticks, inInclusiveRange(55, 65));
      expect(c.totalMs, 960);
      expect(journal.rows.length, writes);
      clock.now += 16;
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('total-time'))).data,
        '00:00.97',
      );
      await c.stop();
      expect(journal.rows.last['closed']['durationMs'], 976);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'opening saved records stops display frames without stopping measurement',
    (tester) async {
      final journal = MemoryJournal();
      final clock = TestClock();
      final c = DisplayRecorder(journal, clock);
      await tester.pumpWidget(ActionCaptureApp(recorder: c));
      await pumpCaptureUi(tester);
      await c.capture('Planting');
      await pumpCaptureUi(tester);
      await tester.tap(find.byTooltip('Study options'));
      await pumpCaptureUi(tester);
      await tester.tap(find.text('Saved records'));
      await pumpCaptureUi(tester);
      final ticks = c.ticks.value;
      clock.now += 2000;
      await tester.pump(const Duration(seconds: 2));
      expect(c.ticks.value, ticks);
      expect(c.running, true);
      expect(journal.rows.length, 1);
      await tester.pageBack();
      await pumpCaptureUi(tester);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('total-time'))).data,
        '00:02.00',
      );
      await c.stop();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('stopped capture has no periodic display signals', (
    tester,
  ) async {
    final journal = MemoryJournal();
    final clock = TestClock();
    final c = DisplayRecorder(journal, clock);
    await tester.pumpWidget(ActionCaptureApp(recorder: c));
    await pumpCaptureUi(tester);
    var ticks = c.ticks.value;
    clock.now += 1000;
    await tester.pump(const Duration(seconds: 1));
    expect(c.ticks.value, ticks);
    await c.capture('Planting');
    await pumpCaptureUi(tester);
    clock.now += 1000;
    await tester.pump(const Duration(milliseconds: 16));
    await c.stop();
    await pumpCaptureUi(tester);
    ticks = c.ticks.value;
    clock.now += 1000;
    await tester.pump(const Duration(seconds: 1));
    expect(c.ticks.value, ticks);
    expect(c.totalMs, 1000);
    expect(journal.rows.length, 2);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'disposing a pending capture releases its ticker before delayed I/O',
    (tester) async {
      final journal = MemoryJournal();
      final clock = TestClock();
      final c = DisplayRecorder(journal, clock);
      await tester.pumpWidget(ActionCaptureApp(recorder: c));
      await pumpCaptureUi(tester);
      journal.barrier = Completer<void>();
      final save = c.capture('Planting');
      await pumpCaptureUi(tester);
      await tester.pumpWidget(const SizedBox());
      final ticks = c.ticks.value;
      clock.now += 1000;
      await tester.pump(const Duration(seconds: 1));
      expect(c.ticks.value, ticks);
      journal.barrier!.complete();
      await save;
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );
}
