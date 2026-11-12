import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:field_tms/actions/action_app.dart';
import 'package:field_tms/actions/action_journal.dart';
import 'package:field_tms/actions/action_recorder.dart';
import 'package:field_tms/actions/delay_audio.dart';
import 'package:field_tms/actions/versioned_action_journal.dart';
import 'package:field_tms/motion/motion_tracker.dart';
import 'action_capture_test.dart' show TestClock, TestLocation, MemoryJournal;
import 'capture_test_pump.dart';

class TestAudio extends DelayAudio {
  final targets = <String?>[];
  final deleted = <String>[];
  Completer<Map<String, dynamic>?>? permission;
  String? current;
  bool failDelete = false;
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  @override
  Future<Map<String, dynamic>?> setTarget(String? file) async {
    targets.add(file);
    if (file != null) {
      current = file;
      if (permission != null) return permission!.future;
      return {'file': file, 'status': 'recording'};
    }
    final old = current;
    current = null;
    return old == null ? null : {'file': old, 'status': 'saved'};
  }

  @override
  Future<void> deleteStudy(String studyId) async {
    if (failDelete) throw StateError('Busy audio file');
    deleted.add(studyId);
  }
}

ActionRecorder make(ActionJournal journal, TestClock clock, TestAudio audio) =>
    ActionRecorder(
      journal,
      clock: clock,
      location: TestLocation(),
      motion: UnavailableMotionTracker(),
      audio: audio,
    );
Future<List<Map<String, dynamic>>> records(ActionJournal journal) async =>
    const LineSplitter()
        .convert(utf8.decode(await journal.csv().expand((e) => e).toList()))
        .skip(1)
        .map(decodeActionEvent)
        .toList();

class ResetMemoryJournal extends MemoryJournal
    implements ResettableActionJournal {
  @override
  Future<void> resetStudy(
    String studyId,
    Map<String, dynamic> replacement,
  ) async {
    rows.removeWhere((e) => (e['state'] as Map)['studyId'] == studyId);
    rows.add(replacement);
    for (var i = 0; i < rows.length; i++) {
      rows[i]['seq'] = i + 1;
      (rows[i]['state'] as Map)['seq'] = i + 1;
    }
  }
}

void main() {
  test(
    'a shorter legacy lap cache is restored to twelve from bounded saved pages',
    () async {
      final j = MemoryJournal();
      final clock = TestClock();
      final audio = TestAudio();
      var c = make(j, clock, audio);
      await c.initialize();
      for (var i = 0; i < 10; i++) {
        await c.capture('Planting');
        clock.now += 10;
        await c.capture('Walking');
        clock.now += 10;
      }
      await c.stop();
      await c.close();
      final state = j.rows.last['state'] as Map;
      state['recentIntervals'] = (state['recentIntervals'] as List)
          .take(3)
          .toList();
      final writes = j.rows.length;
      c = make(j, clock, audio);
      await c.initialize();
      expect(c.recentIntervals.length, 12);
      expect(j.rows.length, writes);
      await c.close();
    },
  );
  test(
    'Reset durably removes only the current study, keeps its name and resets cycles, laps and totals',
    () async {
      final dir = await Directory.systemTemp.createTemp('field-reset-');
      final clock = TestClock();
      final audio = TestAudio();
      var journal = await openVersionedActionJournal(dir);
      var c = make(journal, clock, audio);
      try {
        await c.initialize();
        await c.renameStudy('Pine trial');
        await c.capture('Planting');
        clock.now += 1000;
        await c.stop();
        final retainedId = c.studyId;
        await c.newStudy(title: 'South block');
        await c.capture('Planting');
        clock.now += 2000;
        await c.setDelay(true);
        await c.audioSettled;
        clock.now += 1000;
        await c.capture('Walking');
        await c.audioSettled;
        clock.now += 400;
        await c.stop();
        final erasedId = c.studyId;
        expect(c.totalMs, 3400);
        await c.resetStudy();
        expect(c.title, 'South block');
        expect(c.totalMs, 0);
        expect(c.cycle, 0);
        expect(c.count, 0);
        expect(c.recentIntervals, isEmpty);
        expect(c.cumulativeActivityMs('Planting'), 0);
        expect(audio.deleted, [erasedId]);
        final saved = await records(journal);
        expect(
          saved.any((e) => (e['state'] as Map)['studyId'] == erasedId),
          false,
        );
        expect(
          saved.any((e) => (e['state'] as Map)['studyId'] == retainedId),
          true,
        );
        expect(
          saved.map((e) => e['seq']),
          List.generate(saved.length, (i) => i + 1),
        );
        await c.close();
        journal = await openVersionedActionJournal(dir);
        c = make(journal, clock, audio);
        await c.initialize();
        expect(c.title, 'South block');
        expect(c.totalMs, 0);
        await c.capture('Planting');
        expect(c.cycle, 1);
        clock.now += 10;
        await c.stop();
        await c
            .resetStudy(); // A second manifest commit replaces the first safely.
        expect(c.totalMs, 0);
        expect(c.title, 'South block');
        await c.close();
        journal = await openVersionedActionJournal(dir);
        c = make(journal, clock, audio);
        await c.initialize();
        expect(c.totalMs, 0);
        expect(c.title, 'South block');
      } finally {
        await c.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'Reset is blocked while running and failed audio cleanup remains retryable',
    () async {
      final dir = await Directory.systemTemp.createTemp('field-reset-cleanup-');
      final audio = TestAudio();
      final clock = TestClock();
      final journal = await openVersionedActionJournal(dir);
      final c = make(journal, clock, audio);
      try {
        await c.initialize();
        await c.capture('Planting');
        await expectLater(c.resetStudy(), throwsStateError);
        clock.now += 100;
        await c.stop();
        final old = c.studyId;
        audio.failDelete = true;
        await expectLater(c.resetStudy(), throwsStateError);
        expect(c.totalMs, 0);
        expect(c.canReset, true);
        audio.failDelete = false;
        await c.resetStudy();
        expect(audio.deleted, [old]);
        expect(c.canReset, false);
      } finally {
        await c.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'Delay permission is independent of saved boundaries and cannot revive ended Delay',
    () async {
      final j = MemoryJournal();
      final clock = TestClock();
      final audio = TestAudio()..permission = Completer();
      final c = make(j, clock, audio);
      await c.initialize();
      await c.capture('Planting');
      clock.now += 1000;
      await c.setDelay(true);
      final key = audio.targets.single;
      expect(j.rows.last['kind'], 'delay_start');
      expect(c.pending, 0);
      await c.chooseDelayReason('Personal');
      clock.now += 2000;
      await c.capture('Walking');
      expect(audio.targets, [key, null]);
      expect(
        j.rows
            .where((e) => e['kind'] == 'action')
            .single['delayClosed']['durationMs'],
        2000,
      );
      audio.permission!.complete({'file': key, 'status': 'cancelled'});
      await c.audioSettled;
      expect(c.delayRunning, false);
      expect(c.audioStatus, 'off');
      expect(c.totalMs, 3000);
      await c.stop();
      await c.close();
    },
  );
  testWidgets(
    'title editing, named New study and confirmed Reset are distinct',
    (tester) async {
      final clock = TestClock();
      final audio = TestAudio();
      final journal = ResetMemoryJournal();
      final c = make(journal, clock, audio);
      await tester.pumpWidget(ActionCaptureApp(recorder: c));
      await pumpCaptureUi(tester);
      await tester.tap(find.text('Field study'));
      await pumpCaptureUi(tester);
      await tester.enterText(find.byType(TextField), 'Pine block');
      await tester.tap(find.text('Save name'));
      await pumpCaptureUi(tester);
      expect(c.title, 'Pine block');
      await tester.tap(find.byKey(const ValueKey('activity-Planting')));
      await pumpCaptureUi(tester);
      await tester.tap(find.byTooltip('Study options'));
      await pumpCaptureUi(tester);
      expect(
        tester
            .widget<PopupMenuItem<String>>(
              find.ancestor(
                of: find.text('Reset'),
                matching: find.byType(PopupMenuItem<String>),
              ),
            )
            .enabled,
        false,
      );
      await tester.tap(find.text('Stop'));
      await pumpCaptureUi(tester);
      await tester.tap(find.byTooltip('Study options'));
      await pumpCaptureUi(tester);
      await tester.tap(find.text('Reset'));
      await pumpCaptureUi(tester);
      expect(
        find.textContaining('Delete all records and audio notes'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await pumpCaptureUi(tester);
      expect(c.count, 1);
      await tester.tap(find.byTooltip('Study options'));
      await pumpCaptureUi(tester);
      await tester.tap(find.text('Reset'));
      await pumpCaptureUi(tester);
      await tester.tap(find.text('Delete and reset'));
      await pumpCaptureUi(tester);
      expect(c.count, 0);
      expect(c.title, 'Pine block');
      await tester.tap(find.byTooltip('Study options'));
      await pumpCaptureUi(tester);
      await tester.tap(find.text('New study'));
      await pumpCaptureUi(tester);
      await tester.enterText(find.byType(TextField), 'Oak block');
      await tester.tap(find.text('Create study'));
      await pumpCaptureUi(tester);
      expect(c.title, 'Oak block');
      expect(c.totalMs, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await c.close();
    },
  );
}
