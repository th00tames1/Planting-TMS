import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:field_tms/actions/action_journal.dart';
import 'package:field_tms/actions/capture_time.dart';
import 'package:field_tms/actions/versioned_action_journal.dart';
import 'action_capture_test.dart'
    show MemoryJournal, TestClock, TestLocation, recorder;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Planting and Walking share a cycle; delay starts count per interval; return flow is guarded',
    () async {
      final j = MemoryJournal();
      final clock = TestClock();
      var c = recorder(j, clock);
      await c.initialize();
      expect(c.canCapture('Preparation'), false);
      await c.capture('Planting');
      expect(c.cycle, 1);
      clock.now = 2000;
      await c.setDelay(true);
      expect(c.activityDelayCount, 1);
      await c.chooseDelayReason('Personal');
      clock.now = 2500;
      await c.setDelay(false);
      expect(c.activityDelayCount, 1);
      clock.now = 3000;
      await c.setDelay(true);
      await c.chooseDelayReason('Administrative');
      expect(c.activityDelayCount, 2);
      clock.now = 3500;
      await c.capture('Walking');
      expect(c.cycle, 1);
      expect(c.activityDelayCount, 0);
      expect(c.displayDelayCount('Planting'), 2);
      final closed = j.rows.last;
      expect(closed['closed']['cycle'], 1);
      expect(closed['closed']['delayCount'], 2);
      expect(closed['delayClosed']['cycle'], 1);
      expect(closed['delayClosed']['ordinal'], 2);
      final cells = _cells(encodeActionEvent(closed));
      expect(cells['cycle'], '1');
      expect(cells['activity_delay_count'], '2');
      expect(cells['delay_cycle'], '1');
      expect(cells['delay_ordinal'], '2');
      clock.now = 4000;
      await c.setDelay(true);
      clock.now = 5000;
      await c.capture('Planting');
      expect(j.rows.last['closed']['cycle'], 1);
      expect(j.rows.last['closed']['delayCount'], 1);
      expect(c.cycle, 2);
      expect(c.displayDelayCount('Planting'), 0);
      clock.now = 5100;
      await c.capture('Planting');
      expect(
        c.cycle,
        2,
        reason: 'Duplicate taps cannot create phantom cycles.',
      );
      expect(c.actionMs, 100);
      clock.now = 5500;
      await c.capture('Walk out');
      expect(c.canCapture('Preparation'), true);
      expect(c.canCapture('Planting'), true);
      expect(c.canCapture('Walking'), false);
      final saved = j.rows.length;
      await c.capture('Walking');
      expect(j.rows.length, saved);
      clock.now = 5700;
      await c.capture('Preparation');
      expect(j.rows.last['closed']['cycle'], isNull);
      expect(c.canCapture('Preparation'), false);
      expect(c.canCapture('Planting'), true);
      clock.now = 6000;
      await c.capture('Planting');
      expect(
        c.cycle,
        3,
        reason: 'Every fresh Planting interval starts the next cycle.',
      );
      clock.now = 6500;
      await c.capture('Walking');
      await c.stop();
      await c.close();
      clock.now = 10000;
      c = recorder(j, clock);
      await c.initialize();
      await c.capture('Planting');
      expect(c.cycle, 4);
      expect(c.activityDelayCount, 0);
      await c.stop();
      await c.newStudy();
      expect(c.cycle, 0);
      expect(c.displayDelayCount('Planting'), 0);
      await c.close();
    },
  );

  test(
    'actual v2 originals are preserved while v4 exports readable cycle and delay counts',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'field-cycle-migration-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final original = await File(
        'test/fixtures/legacy_action_events_v2.csv',
      ).readAsBytes();
      final old = File('${dir.path}/action-events-v2.csv');
      await old.writeAsBytes(original, flush: true);
      final journal = await openVersionedActionJournal(dir);
      final clock = TestClock();
      final c = recorder(journal, clock);
      await c.initialize();
      expect(c.sequence, 8);
      await c.capture('Planting');
      clock.now = 2000;
      await c.setDelay(true);
      await c.chooseDelayReason('Administrative');
      clock.now = 2500;
      await c.stop();
      final bytes = await journal.csv().expand((chunk) => chunk).toList();
      final lines = const LineSplitter().convert(utf8.decode(bytes));
      expect('${lines.first}\n', actionCsvHeader);
      final events = lines.skip(1).map(decodeActionEvent).toList();
      expect(
        events.map((event) => event['seq']),
        List.generate(events.length, (i) => i + 1),
      );
      final last = _cells(lines.last);
      expect(last['schema'], '4');
      expect(last['cycle'], '1');
      expect(last['activity_delay_count'], '1');
      expect(last['delay_ordinal'], '1');
      expect(last['delay_reason'], 'Administrative');
      await c.close();
      expect(await old.readAsBytes(), original);
    },
  );

  test(
    'Administrative delay survives reopen and Stop cannot resume timing',
    () async {
      final j = MemoryJournal();
      final clock = TestClock();
      var c = recorder(j, clock);
      await c.initialize();
      await c.capture('Planting');
      expect(j.rows.length, 1);
      expect(j.rows.single['kind'], 'start');
      expect(c.action, 'Planting');
      clock.now = 2000;
      await c.setDelay(true);
      await c.chooseDelayReason('Administrative');
      await c.close();
      clock.now = 4000;
      c = recorder(j, clock);
      await c.initialize();
      expect(c.delayReason, 'Administrative');
      expect(c.delayMs, 2000);
      await c.stop();
      expect(j.rows.last['closed']['durationMs'], 3000);
      expect(j.rows.last['delayClosed']['durationMs'], 2000);
      final cells = _cells(encodeActionEvent(j.rows.last));
      expect(cells['delay_reason'], 'Administrative');
      expect(cells['total_elapsed_ms'], '3000');
      final saved = j.rows.length;
      await c.stop();
      expect(c.running, false);
      expect(j.rows.length, saved);
      clock.now = 10000;
      await c.capture('Planting');
      expect(c.actionMs, 0);
      expect(c.totalMs, 3000);
      expect(c.delayRunning, false);
      await c.close();
    },
  );

  test(
    'stopwatch readout rolls over minutes and hours without losing stored precision',
    () {
      for (final sample in <int?, String>{
        null: '—',
        0: '00:00.00',
        1234: '00:01.23',
        59999: '00:59.99',
        60000: '01:00.00',
        3599999: '59:59.99',
        3600000: '01:00:00.00',
        28801234: '08:00:01.23',
      }.entries) {
        expect(captureTime(sample.key), sample.value);
      }
    },
  );

  test(
    'Delay overlaps the base activity and switching closes both at one boundary',
    () async {
      final journal = MemoryJournal();
      final clock = TestClock();
      final c = recorder(journal, clock);
      await c.initialize();
      await c.select('Planting');
      await c.setDelay(true); // Idle gestures never create a delay.
      expect(c.delayRunning, false);
      await c.startStop();
      clock.now = 2000;
      await c.setDelay(true);
      clock.now = 2500;
      await c.chooseDelayReason('Personal');
      clock.now = 4000;
      await c.select('Planting'); // Repeating the base does not end the delay.
      expect(c.delayRunning, true);
      expect(c.action, 'Planting');
      expect(c.displayMs('Planting'), 3000);
      expect(c.displayMs('Delay'), 2000);
      expect(c.totalMs, 3000);
      clock.now = 6000;
      await c.select('Walking');
      final transition = journal.rows.last;
      expect(transition['closed']['durationMs'], 5000);
      expect(transition['delayClosed']['durationMs'], 4000);
      expect(transition['delayClosed']['reason'], 'Personal');
      expect(transition['delayClosed']['parentActivity'], 'Planting');
      expect(transition['delayClosed']['reasonAt']['monoMs'], 2500);
      expect(transition['closed']['end'], transition['delayClosed']['end']);
      expect(transition['delayClosed']['start']['location']['latitude'], 45);
      expect(transition['delayClosed']['end']['location']['latitude'], 45);
      expect(c.delayRunning, false);
      expect(c.totalMs, 5000);
      expect(c.count, 1);
      expect(c.delayCount, 1);
      expect(c.displayMs('Planting'), 0);
      expect(c.cumulativeActivityMs('Planting'), 5000);
      expect(c.displayMs('Walking'), 0);
      expect(c.displayMs('Delay'), 4000);
      expect(c.recentIntervals.map((e) => e['number']), [2, 1]);
      expect(c.recentIntervals.map((e) => e['overlap']), [false, true]);
      final cells = _cells(encodeActionEvent(transition));
      expect(cells['duration_ms'], '5000');
      expect(cells['delay_duration_ms'], '4000');
      expect(cells['delay_reason'], 'Personal');
      expect(cells['delay_is_overlap'], 'true');
      expect(cells['total_elapsed_ms'], '5000');
      expect(cells['decimal_minutes'], '0.083333333');
      expect(cells['delay_decimal_minutes'], '0.066666667');
      expect(
        decodeActionEvent(encodeActionEvent(transition).trimRight()),
        transition,
      );
      await c.close();
    },
  );

  test(
    'explicit Delay end, repeated reasons, Stop and Resume preserve the base anchor',
    () async {
      final j = MemoryJournal();
      final clock = TestClock();
      final c = recorder(j, clock);
      await c.initialize();
      await c.startStop();
      clock.now = 2000;
      await c.setDelay(true);
      clock.now = 2200;
      await c.chooseDelayReason('Operational');
      clock.now = 3000;
      await c.setDelay(false);
      expect(c.actionMs, 2000);
      expect(c.running, true);
      expect(c.count, 0);
      expect(c.delayCount, 1);
      expect(j.rows.last['closed'], isNull);
      expect(j.rows.last['delayClosed']['durationMs'], 1000);
      clock.now = 4000;
      await c.setDelay(true);
      await c.chooseDelayReason('Mechanical');
      clock.now = 6000;
      await c.startStop();
      expect(c.totalMs, 5000);
      expect(c.count, 1);
      expect(c.delayCount, 2);
      expect(c.delayRunning, false);
      expect(c.lastDelayReason, 'Mechanical');
      expect(j.rows.last['closed']['durationMs'], 5000);
      expect(j.rows.last['delayClosed']['durationMs'], 2000);
      clock.now = 100000;
      await c.startStop();
      expect(c.delayRunning, false);
      expect(c.displayMs('Walking'), 0);
      clock.now = 101000;
      await c.startStop();
      expect(c.totalMs, 6000);
      await c.newStudy();
      expect(c.recentIntervals, isEmpty);
      expect(c.displayMs('Delay'), 0);
      expect(c.lastDelayReason, isNull);
      await c.close();
    },
  );

  test(
    'failed transition retains both running timers; retry closes both at original time',
    () async {
      final j = MemoryJournal();
      final clock = TestClock();
      final c = recorder(j, clock);
      await c.initialize();
      await c.startStop();
      clock.now = 2000;
      await c.setDelay(true);
      await c.chooseDelayReason('Personal');
      j.fail = true;
      clock.now = 3000;
      final failed = c.select('Planting');
      clock.now = 3500;
      final queued = c.chooseDelayReason('Mechanical');
      await Future.wait([failed, queued]);
      expect(c.action, 'Walking');
      expect(c.delayRunning, true);
      expect(c.delayReason, 'Personal');
      expect(c.count, 0);
      j.fail = false;
      clock.now = 9000;
      await c.retrySave();
      expect(c.action, 'Planting');
      expect(c.delayRunning, false);
      expect(c.actionMs, 6000);
      expect(c.totalMs, 8000);
      expect(j.rows.last['closed']['durationMs'], 2000);
      expect(j.rows.last['delayClosed']['durationMs'], 1000);
      expect(j.rows.last['delayClosed']['reason'], 'Personal');
      expect(j.rows.last['delayClosed']['end']['monoMs'], 3000);
      await c.close();
    },
  );

  test(
    'process recovery retains overlap; reboot marks both durations unknown',
    () async {
      final j = MemoryJournal();
      final clock = TestClock();
      var c = recorder(j, clock);
      await c.initialize();
      await c.startStop();
      clock.now = 2000;
      await c.setDelay(true);
      await c.chooseDelayReason('Personal');
      await c.close();
      clock.now = 4000;
      c = recorder(j, clock);
      await c.initialize();
      expect(c.delayRunning, true);
      expect(c.delayReason, 'Personal');
      expect(c.totalMs, 3000);
      expect(c.delayMs, 2000);
      await c.close();
      clock.now = 100;
      c = recorder(j, clock, location: TestLocation()..bootId = 'boot-b');
      await c.initialize();
      expect(c.needsReview, true);
      expect(c.delayMs, isNull);
      await c.closeInterrupted();
      final e = j.rows.last;
      expect(e['closed']['durationMs'], isNull);
      expect(e['delayClosed']['durationMs'], isNull);
      expect(e['closed']['end'], isNull);
      expect(e['delayClosed']['end'], isNull);
      expect(c.totalMs, 3000);
      expect(c.displayMs('Walking'), 0);
      expect(c.cumulativeActivityMs('Walking'), isNull);
      expect(c.displayMs('Delay'), isNull);
      final cells = _cells(encodeActionEvent(e));
      expect(cells['delay_duration_ms'], '');
      expect(cells['delay_end_latitude'], '');
      expect(cells['delay_end_utc'], '');
      await c.close();
    },
  );

  test(
    'recent laps persist beyond the bounded event window and process restart',
    () async {
      final j = MemoryJournal();
      final clock = TestClock();
      var c = recorder(j, clock);
      await c.initialize();
      await c.startStop();
      clock.now = 2000;
      await c.select('Planting');
      for (var i = 0; i < 30; i++) {
        clock.now += 100;
        await c.select('Planting');
      }
      expect(c.events.length, 20);
      expect(c.recentIntervals.single['action'], 'Walking');
      expect(c.recentIntervals.single['durationMs'], 1000);
      await c.close();
      c = recorder(j, clock);
      await c.initialize();
      expect(c.recentIntervals.single['action'], 'Walking');
      expect(c.recentIntervals.single['durationMs'], 1000);
      expect(c.recentIntervals.single.keys, isNot(contains('start')));
      await c.close();
    },
  );
  test(
    'a stopped legacy exclusive Delay defaults to a usable base activity',
    () async {
      final lines = await File(
        'test/fixtures/legacy_action_events.csv',
      ).readAsLines();
      final old = decodeActionEvent(lines.last);
      final state = old['state'] as Map;
      state['action'] = 'Delay';
      state['running'] = false;
      state['active'] = null;
      final j = MemoryJournal()..rows.add(old);
      final clock = TestClock();
      final c = recorder(j, clock);
      await c.initialize();
      expect(c.action, 'Walking');
      await c.startStop();
      expect(c.running, true);
      expect(c.action, 'Walking');
      expect(c.delayRunning, false);
      expect((old['state'] as Map)['action'], 'Delay');
      clock.now = 2000;
      await c.startStop();
      expect(j.rows.last['closed']['action'], 'Walking');
      expect(j.rows.last['closed']['durationMs'], 1000);
      await c.close();
    },
  );
  test(
    'v1 captures stay byte-identical while v4 appends and streams a combined CSV',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'field-overlap-migration-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final original = await File(
        'test/fixtures/legacy_action_events.csv',
      ).readAsBytes();
      final legacy = File('${directory.path}/action-events-v1.csv');
      await legacy.writeAsBytes(original, flush: true);
      var journal = await openVersionedActionJournal(directory);
      expect((await journal.recent()).last['seq'], 3);
      final clock = TestClock();
      var c = recorder(journal, clock);
      await c.initialize();
      expect(c.needsReview, true);
      await c.closeInterrupted();
      await c.newStudy();
      await c.startStop();
      clock.now = 2000;
      await c.setDelay(true);
      await c.chooseDelayReason('Personal');
      await c.close();
      expect(await legacy.readAsBytes(), original);
      journal = await openVersionedActionJournal(directory);
      clock.now = 5000;
      c = recorder(journal, clock);
      await c.initialize();
      expect(c.delayReason, 'Personal');
      expect(c.delayMs, 3000);
      await c.select('Planting');
      final bytes = await journal.csv().expand((chunk) => chunk).toList();
      final lines = const LineSplitter().convert(utf8.decode(bytes));
      expect('${lines.first}\n', actionCsvHeader);
      final events = lines.skip(1).map(decodeActionEvent).toList();
      expect(
        events.map((e) => e['seq']),
        List.generate(events.length, (i) => i + 1),
      );
      expect(events.last['delayClosed']['durationMs'], 3000);
      expect(events.last['closed']['durationMs'], 4000);
      expect(_cells(lines.last)['delay_reason'], 'Personal');
      await c.close();
      expect(await legacy.readAsBytes(), original);
      // Only the uncommitted current tail is repaired; legacy bytes persist.
      final v2 = File('${directory.path}/action-events-v4.csv');
      final valid = await v2.readAsBytes();
      await v2.writeAsString('incomplete', mode: FileMode.append, flush: true);
      journal = await openVersionedActionJournal(directory);
      await journal.close();
      expect(await v2.readAsBytes(), valid);
      expect(await legacy.readAsBytes(), original);
    },
  );
}

Map<String, String> _cells(String encoded) {
  final values = encoded
      .trimRight()
      .substring(1, encoded.trimRight().length - 1)
      .split('","');
  return Map.fromIterables(actionCsvColumns, values);
}
