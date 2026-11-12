import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:field_tms/actions/action_app.dart';
import 'package:field_tms/actions/action_journal.dart';
import 'package:field_tms/actions/action_journal_native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'action_capture_test.dart'
    show MemoryJournal, TestClock, TestLocation, recorder;
import 'capture_test_pump.dart';

class BoundedTotalsJournal extends MemoryJournal {
  bool forbidScan = false;
  @override
  Future<List<Map<String, dynamic>>> recent() async =>
      rows.reversed.take(20).toList().reversed.toList();
  @override
  Stream<Uint8List> csv() async* {
    if (forbidScan) throw StateError('Cached totals must not scan history.');
    yield* super.csv();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'only new Planting intervals start cycles, including directly from Walk out',
    () async {
      final journal = MemoryJournal();
      final clock = TestClock();
      final c = recorder(journal, clock);
      await c.initialize();
      await c.capture('Walking');
      expect(c.cycle, 0);
      await c.capture('Walk out');
      await c.capture('Preparation');
      expect(c.cycle, 0);
      await c.capture('Planting');
      expect(c.cycle, 1);
      await c.capture('Planting');
      expect(c.cycle, 1);
      await c.capture('Walk out');
      expect(c.canCapture('Planting'), true);
      expect(c.canCapture('Walking'), false);
      await c.capture('Planting');
      expect(c.cycle, 2);
      await c.capture('Walking');
      expect(c.cycle, 2);
      await c.close();
    },
  );

  test(
    'totals accumulate gross intervals once, survive reopen and reset for a new study',
    () async {
      final journal = MemoryJournal();
      final clock = TestClock();
      var c = recorder(journal, clock);
      await c.initialize();
      await c.capture('Planting');
      clock.now = 2000;
      await c.setDelay(true);
      clock.now = 3000;
      await c.capture('Walking');
      expect(c.cumulativeActivityMs('Planting'), 2000);
      expect(c.displayMs('Planting'), 0);
      clock.now = 4500;
      expect(c.cumulativeActivityMs('Walking'), 1500);
      await c.capture('Planting');
      clock.now = 5000;
      await c.stop();
      expect(c.cumulativeActivityMs('Planting'), 2500);
      expect(c.cumulativeActivityMs('Walking'), 1500);
      expect(c.displayMs('Planting'), 0);
      expect(c.totalMs, 4000);
      await c.close();
      c = recorder(journal, clock);
      await c.initialize();
      expect(c.cumulativeActivityMs('Planting'), 2500);
      expect(c.cumulativeActivityMs('Walking'), 1500);
      await c.newStudy();
      expect(c.cumulativeActivityMs('Planting'), 0);
      expect(c.cumulativeActivityMs('Walking'), 0);
      await c.close();
    },
  );

  test(
    'legacy total restoration reads beyond 20 recent events and persists a compact cache',
    () async {
      final journal = BoundedTotalsJournal();
      final clock = TestClock();
      var c = recorder(journal, clock);
      await c.initialize();
      for (var i = 0; i < 65; i++) {
        await c.capture(i.isEven ? 'Planting' : 'Walking');
        clock.now += 100;
      }
      await c.stop();
      await c.close();
      for (final row in journal.rows) {
        (row['state'] as Map).remove('activityTotalsMs');
      }
      final original = jsonEncode(journal.rows);
      c = recorder(journal, clock);
      await c.initialize();
      expect(c.cumulativeActivityMs('Planting'), 3300);
      expect(c.cumulativeActivityMs('Walking'), 3200);
      expect(jsonEncode(journal.rows), original);
      await c.capture('Planting');
      expect(journal.rows.last['state']['activityTotalsMs']['Planting'], 3300);
      await c.stop();
      await c.close();
      journal.forbidScan = true;
      c = recorder(journal, clock);
      await c.initialize();
      expect(c.cumulativeActivityMs('Planting'), 3300);
      expect(c.cumulativeActivityMs('Walking'), 3200);
      journal.forbidScan = false;
      await c.newStudy();
      await c.capture('Walking');
      clock.now += 550;
      await c.stop();
      await c.close();
      (journal.rows.last['state'] as Map).remove('activityTotalsMs');
      c = recorder(journal, clock);
      await c.initialize();
      expect(c.cumulativeActivityMs('Planting'), 0);
      expect(c.cumulativeActivityMs('Walking'), 550);
      await c.close();
    },
  );

  test(
    'native CSV appends total cache without rewriting original records',
    () async {
      final dir = await Directory.systemTemp.createTemp('tms-totals-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/events.csv');
      final source = MemoryJournal();
      final clock = TestClock();
      var c = recorder(source, clock);
      await c.initialize();
      await c.capture('Planting');
      clock.now += 1234;
      await c.stop();
      await c.close();
      for (final row in source.rows) {
        (row['state'] as Map).remove('activityTotalsMs');
      }
      final original = utf8.encode(
        actionCsvHeader + source.rows.map(encodeActionEvent).join(),
      );
      await file.writeAsBytes(original, flush: true);
      var journal = await FileActionJournal.open(file);
      c = recorder(journal, clock);
      await c.initialize();
      expect(c.cumulativeActivityMs('Planting'), 1234);
      await c.capture('Walking');
      clock.now += 765;
      await c.stop();
      await c.close();
      expect((await file.readAsBytes()).take(original.length), original);
      journal = await FileActionJournal.open(file);
      c = recorder(journal, clock);
      await c.initialize();
      expect(c.cumulativeActivityMs('Planting'), 1234);
      expect(c.cumulativeActivityMs('Walking'), 765);
      await c.close();
    },
  );

  test(
    'an interrupted interval makes only its own cumulative duration unknown',
    () async {
      final journal = MemoryJournal();
      final clock = TestClock();
      var c = recorder(journal, clock);
      await c.initialize();
      await c.capture('Planting');
      clock.now += 1000;
      await c.capture('Walking');
      await c.close();
      c = recorder(journal, clock, location: TestLocation()..bootId = 'boot-b');
      await c.initialize();
      expect(c.cumulativeActivityMs('Planting'), 1000);
      expect(c.cumulativeActivityMs('Walking'), isNull);
      await c.closeInterrupted();
      expect(c.cumulativeActivityMs('Walking'), isNull);
      expect(c.cumulativeActivityMs('Planting'), 1000);
      await c.close();
    },
  );

  testWidgets(
    'paired clocks reset immediately while totals keep pending gesture time',
    (tester) async {
      final journal = MemoryJournal();
      final clock = TestClock();
      final c = recorder(journal, clock);
      await tester.pumpWidget(ActionCaptureApp(recorder: c));
      await pumpCaptureUi(tester);
      String text(String key) =>
          tester.widget<Text>(find.byKey(ValueKey(key))).data!;
      await tester.tap(find.byKey(const ValueKey('activity-Planting')));
      await pumpCaptureUi(tester);
      clock.now = 3000;
      await tester.pump(const Duration(milliseconds: 200));
      expect(text('activity-total-Planting'), 'Total 00:02.00');
      journal.barrier = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('activity-Walking')));
      await tester.pump();
      expect(text('activity-time-Planting'), '00:00.00');
      expect(text('activity-total-Planting'), 'Total 00:02.00');
      clock.now = 3500;
      await tester.pump(const Duration(milliseconds: 200));
      expect(text('activity-total-Walking'), 'Total 00:00.50');
      await tester.tap(find.byKey(const ValueKey('activity-Planting')));
      await tester.pump();
      expect(text('activity-time-Walking'), '00:00.00');
      expect(text('activity-total-Walking'), 'Total 00:00.50');
      expect(text('activity-time-Planting'), '00:00.00');
      clock.now = 3700;
      await tester.pump(const Duration(milliseconds: 200));
      expect(text('activity-total-Planting'), 'Total 00:02.20');
      journal.barrier!.complete();
      await pumpCaptureUi(tester);
      expect(text('activity-total-Planting'), 'Total 00:02.20');
      expect(text('activity-total-Walking'), 'Total 00:00.50');
      expect(c.cycle, 2);
      await c.stop();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
