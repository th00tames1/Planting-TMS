import 'dart:async';
import 'dart:io';

import 'package:field_tms/actions/action_app.dart';
import 'package:field_tms/actions/action_journal.dart';
import 'package:field_tms/actions/delay_audio.dart';
import 'package:field_tms/actions/action_journal_native.dart';
import 'package:field_tms/actions/saved_records_screen.dart';
import 'package:field_tms/actions/versioned_action_journal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'action_capture_test.dart' show MemoryJournal, TestClock, recorder;
import 'capture_test_pump.dart';

Map<String, dynamic> event(int sequence, {String note = ''}) => {
  'seq': sequence,
  'kind': 'action',
  'boundary': {'utc': '2026-10-28T18:00:00.000Z', 'monoMs': sequence * 1500},
  'totalMs': sequence * 1500,
  'closed': {
    'action': 'Planting',
    'durationMs': 1500,
    'cycle': (sequence / 2).ceil(),
    'delayCount': 2,
    'start': {'utc': '2026-10-28T17:59:58.500Z'},
    'end': {'utc': '2026-10-28T18:00:00.000Z'},
  },
  'state': {'studyId': 'records-test', 'running': false, 'action': 'Walking'},
  if (note.isNotEmpty) 'note': note,
};

class GatedJournal extends MemoryJournal implements PagedActionJournal {
  Completer<void>? readBarrier;
  bool failRead = false;
  int reads = 0;
  @override
  Future<ActionJournalPage> readPage({
    String? cursor,
    int limit = 50,
    required int maxSequence,
  }) async {
    reads++;
    await readBarrier?.future;
    if (failRead) throw const FileSystemException('Read failed');
    final before = cursor == null ? maxSequence + 1 : int.parse(cursor);
    final eligible = rows.reversed
        .where((row) => row['seq'] < before && row['seq'] <= maxSequence)
        .take(limit + 1)
        .toList();
    final more = eligible.length > limit;
    if (more) eligible.removeLast();
    return ActionJournalPage(
      eligible,
      nextCursor: more ? '${eligible.last['seq']}' : null,
    );
  }
}

class RecordAudio extends DelayAudio {
  final played = <String>[];
  final completed = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  Set<String> available = {};
  int stops = 0;
  Object? playError;
  @override
  Stream<Map<String, dynamic>> get playbackEvents => completed.stream;
  @override
  Future<Set<String>> availableFiles(Iterable<String> files) async =>
      files.where(available.contains).toSet();
  @override
  Future<void> stopPlayback() async {
    stops++;
  }

  @override
  Future<void> play(String file) async {
    if (playError != null) throw playError!;
    played.add(file);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'native pages cross chunk boundaries and retain accepted snapshot',
    () async {
      final dir = await Directory.systemTemp.createTemp('tms-record-page-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/journal.csv');
      final journal = await FileActionJournal.open(file);
      for (var i = 1; i <= 126; i++) {
        await journal.append(event(i, note: i == 74 ? '나무🌲' * 1200 : ''));
      }
      expect((await journal.recent()).length, 20);
      final seen = <int>[];
      String? cursor;
      do {
        final page = await journal.readPage(cursor: cursor, maxSequence: 123);
        expect(page.events.length, lessThanOrEqualTo(50));
        seen.addAll(page.events.map((row) => row['seq'] as int));
        cursor = page.nextCursor;
      } while (cursor != null);
      expect(seen, List.generate(123, (i) => 123 - i));
      await journal.append(event(127));
      await journal.close();
      final reopened = await FileActionJournal.open(file);
      expect(reopened.sequence, 127);
      await reopened.close();
    },
  );

  test('invalid page releases the handle without changing CSV', () async {
    final dir = await Directory.systemTemp.createTemp('tms-record-error-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/journal.csv');
    final journal = await FileActionJournal.open(file);
    await journal.append(event(1));
    await expectLater(
      journal.readPage(cursor: '5', maxSequence: 1),
      throwsFormatException,
    );
    await expectLater(
      journal.readPage(cursor: 'not-a-position', maxSequence: 1),
      throwsFormatException,
    );
    await expectLater(
      journal.readPage(limit: 101, maxSequence: 1),
      throwsArgumentError,
    );
    await journal.append(event(2));
    await journal.close();
    final original = await file.readAsBytes();
    final reopened = await FileActionJournal.open(file);
    expect((await reopened.readPage(maxSequence: 2)).events.length, 2);
    await reopened.close();
    expect(await file.readAsBytes(), original);
  });

  test(
    'full history pages across v3, v2 and v1 without rewriting originals',
    () async {
      final dir = await Directory.systemTemp.createTemp('tms-record-versions-');
      addTearDown(() => dir.delete(recursive: true));
      for (var v = 1; v <= 2; v++) {
        await File('${dir.path}/action-events-v$v.csv').writeAsString(
          actionCsvHeaderFor(v) +
              List.generate(
                37,
                (i) => encodeActionEvent(
                  event(i + 1 + (v - 1) * 37),
                  csvVersion: v,
                ),
              ).join(),
        );
      }
      final v1 = await File('${dir.path}/action-events-v1.csv').readAsBytes();
      final v2 = await File('${dir.path}/action-events-v2.csv').readAsBytes();
      final journal = await openVersionedActionJournal(dir);
      for (var i = 75; i <= 125; i++) {
        await journal.append(event(i));
      }
      final rows = <int>[];
      String? cursor;
      do {
        final page = await readActionPage(
          journal,
          cursor: cursor,
          maxSequence: 125,
        );
        rows.addAll(page.events.map((row) => row['seq'] as int));
        cursor = page.nextCursor;
      } while (cursor != null);
      expect(rows, List.generate(125, (i) => 125 - i));
      await journal.append(event(126));
      await journal.close();
      expect(await File('${dir.path}/action-events-v1.csv').readAsBytes(), v1);
      expect(await File('${dir.path}/action-events-v2.csv').readAsBytes(), v2);
    },
  );

  test(
    'CSV details and fallback pages preserve decimal values and legacy blanks',
    () async {
      final journal = MemoryJournal();
      journal.rows.addAll(List.generate(75, (i) => event(i + 1)));
      final first = await readActionPage(journal, maxSequence: 72);
      expect(first.events.first['seq'], 72);
      expect(first.events.last['seq'], 23);
      final older = await readActionPage(
        journal,
        cursor: first.nextCursor,
        maxSequence: 72,
      );
      expect(older.events.first['seq'], 22);
      expect(older.events.last['seq'], 1);
      expect(older.nextCursor, isNull);
      final fields = actionEventFields(first.events.first);
      expect(fields['duration_ms'], '1500');
      expect(fields['decimal_minutes'], '0.025000000');
      expect(fields['cycle'], '36');
      expect(fields['activity_delay_count'], '2');
      expect(fields.containsKey('payload_base64'), false);
      final legacy = event(1);
      (legacy['closed'] as Map).remove('cycle');
      expect(actionEventFields(legacy)['cycle'], '');
    },
  );

  testWidgets(
    'study selection opens paged timetable minutes and returns newer',
    (tester) async {
      final journal = GatedJournal();
      journal.rows.addAll(List.generate(123, (i) => event(i + 1)));
      await tester.pumpWidget(
        MaterialApp(
          home: SavedRecordsScreen(
            journal: journal,
            maxSequence: 123,
            audio: RecordAudio(),
          ),
        ),
      );
      await pumpCaptureUi(tester);
      expect(
        find.byKey(const ValueKey('saved-study-records-test')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('saved-study-records-test')));
      await pumpCaptureUi(tester);
      expect(find.byKey(const ValueKey('time-row-123-closed')), findsOneWidget);
      expect(find.text('Minutes'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('records-older')));
      await pumpCaptureUi(tester);
      expect(find.text('Page 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('time-row-93-closed')), findsOneWidget);
      expect(find.text('0.02500'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('records-older')));
      await pumpCaptureUi(tester);
      expect(find.byKey(const ValueKey('time-row-63-closed')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('records-newer')));
      await pumpCaptureUi(tester);
      expect(find.byKey(const ValueKey('time-row-93-closed')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reading does not pause measurement and back waits for file access',
    (tester) async {
      final journal = GatedJournal();
      final clock = TestClock();
      final c = recorder(journal, clock);
      await tester.pumpWidget(ActionCaptureApp(recorder: c));
      await pumpCaptureUi(tester);
      expect(find.text('Cycle —'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('activity-Planting')));
      await pumpCaptureUi(tester);
      expect(find.text('Cycle 1'), findsOneWidget);
      final time = tester.getRect(find.byKey(const ValueKey('total-time')));
      final cycle = tester.getRect(find.byKey(const ValueKey('current-cycle')));
      expect(cycle.center.dx, greaterThan(time.center.dx));
      expect(cycle.overlaps(time), false);
      expect(
        time.center.dx,
        closeTo(tester.getCenter(find.text('Total time')).dx, 1),
      );
      journal.readBarrier = Completer<void>();
      await tester.tap(find.byTooltip('Study options'));
      await pumpCaptureUi(tester);
      await tester.tap(find.text('Saved records'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 350));
      expect(journal.reads, 1);
      clock.now += 5500;
      expect(c.running, true);
      expect(c.totalMs, 5500);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('Saved records'), findsOneWidget);
      journal.readBarrier!.complete();
      await pumpCaptureUi(tester);
      await tester.pageBack();
      await pumpCaptureUi(tester);
      await tester.tap(find.byKey(const ValueKey('activity-Walking')));
      await pumpCaptureUi(tester);
      expect(journal.rows.last['closed']['durationMs'], 5500);
      expect(c.running, true);
      await c.stop();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('failed older page retries the same page', (tester) async {
    final journal = GatedJournal();
    journal.rows.addAll(List.generate(65, (i) => event(i + 1)));
    await tester.pumpWidget(
      MaterialApp(
        home: SavedRecordsScreen(
          journal: journal,
          maxSequence: 65,
          audio: RecordAudio(),
        ),
      ),
    );
    await pumpCaptureUi(tester);
    await tester.tap(find.byKey(const ValueKey('saved-study-records-test')));
    await pumpCaptureUi(tester);
    journal.failRead = true;
    await tester.tap(find.byKey(const ValueKey('records-older')));
    await pumpCaptureUi(tester);
    expect(find.text('Retry'), findsOneWidget);
    journal.failRead = false;
    await tester.tap(find.text('Retry'));
    await pumpCaptureUi(tester);
    expect(find.text('Page 2'), findsOneWidget);
    expect(find.byKey(const ValueKey('time-row-35-closed')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy stopped selections are not presented as timed starts', (
    tester,
  ) async {
    final journal = MemoryJournal();
    final selection = event(1)..remove('closed');
    journal.rows.add(selection);
    await tester.pumpWidget(
      MaterialApp(
        home: SavedRecordsScreen(
          journal: journal,
          maxSequence: 1,
          audio: RecordAudio(),
        ),
      ),
    );
    await pumpCaptureUi(tester);
    await tester.tap(find.byKey(const ValueKey('saved-study-records-test')));
    await pumpCaptureUi(tester);
    expect(find.text('No completed activities yet.'), findsOneWidget);
    expect(find.text('Walking started'), findsNothing);
  });
}
