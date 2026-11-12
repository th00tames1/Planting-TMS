import 'package:field_tms/actions/study_records.dart';
import 'package:field_tms/actions/saved_records_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'action_records_test.dart' show GatedJournal, RecordAudio, event;
import 'capture_test_pump.dart';

Map<String, dynamic> studyEvent(int sequence, String id, String title) {
  final row = event(sequence);
  row['state'] = {
    'studyId': id,
    'title': title,
    'running': false,
    'action': 'Walking',
  };
  return row;
}

void main() {
  test(
    'study index pages ten projects, keeps latest names and freezes sequence',
    () async {
      final journal = GatedJournal();
      for (var study = 1; study <= 12; study++) {
        for (var n = 0; n < 7; n++) {
          journal.rows.add(
            studyEvent(journal.rows.length + 1, 'study-$study', 'Block $study'),
          );
        }
      }
      (journal.rows.last['state'] as Map)['title'] = 'Renamed block';
      final first = await readStudies(journal, 84);
      expect(first.studies.length, 10);
      expect(first.studies.first.title, 'Renamed block');
      journal.rows.add(studyEvent(85, 'later', 'Not in this view'));
      final older = await readStudies(journal, 84, position: first.next);
      expect(older.studies.map((s) => s.id), ['study-2', 'study-1']);
      expect(older.next, isNull);
      final chosen = first.studies[4];
      final table = await readStudyTimes(
        journal,
        84,
        chosen.id,
        position: chosen.position,
      );
      expect(table.rows.length, 7);
      expect(table.rows.first.id, '56-closed');
      expect(table.rows.last.id, '50-closed');
    },
  );
  test(
    'long study table is bounded and excludes metadata and adjacent studies',
    () async {
      final journal = GatedJournal();
      journal.rows.add(studyEvent(1, 'older', 'Other project'));
      for (var i = 2; i <= 123; i++) {
        journal.rows.add(studyEvent(i, 'target', 'Pine'));
      }
      final meta = studyEvent(124, 'target', 'Pine')..remove('closed');
      journal.rows.add(meta);
      journal.rows.add(studyEvent(125, 'newer', 'Other project'));
      final studies = await readStudies(journal, 125);
      final study = studies.studies.singleWhere((s) => s.id == 'target');
      final ids = <String>[];
      var position = study.position;
      while (true) {
        final page = await readStudyTimes(
          journal,
          125,
          study.id,
          position: position,
        );
        expect(page.rows.length, lessThanOrEqualTo(31));
        ids.addAll(page.rows.map((r) => r.id));
        if (page.next == null) break;
        position = page.next!;
      }
      expect(ids.length, 122);
      expect(ids.first, '123-closed');
      expect(ids.last, '2-closed');
      expect(ids.toSet().length, ids.length);
    },
  );
  testWidgets(
    'selected study shows vertical minutes and inline Delay playback',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final journal = GatedJournal();
      journal.rows.add(studyEvent(1, 'old', 'Oak block'));
      journal.rows.add(studyEvent(2, 'new', 'Pine block'));
      final last = studyEvent(3, 'new', 'Pine block');
      const file = 'note-study-20261112000000000-1-2000.m4a';
      last['delayClosed'] = {
        'action': 'Delay',
        'parentActivity': 'Planting',
        'reason': 'Administrative',
        'durationMs': 500,
        'cycle': 2,
        'audioFile': file,
      };
      journal.rows.add(last);
      final audio = RecordAudio()..available = {file};
      await tester.pumpWidget(
        MaterialApp(
          home: SavedRecordsScreen(
            journal: journal,
            maxSequence: 3,
            audio: audio,
          ),
        ),
      );
      await pumpCaptureUi(tester);
      expect(find.text('Pine block'), findsOneWidget);
      expect(find.text('Oak block'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('saved-study-new')));
      await pumpCaptureUi(tester);
      expect(find.text('Minutes'), findsOneWidget);
      expect(find.text('Administrative'), findsOneWidget);
      expect(find.byKey(const ValueKey('time-row-1-closed')), findsNothing);
      expect(find.text('0.00833'), findsOneWidget);
      expect(find.textContaining('GPS'), findsNothing);
      expect(find.textContaining('timestamp'), findsNothing);
      for (final scroll in tester.widgetList<Scrollable>(
        find.byType(Scrollable),
      )) {
        expect(
          scroll.axisDirection,
          anyOf(AxisDirection.down, AxisDirection.up),
        );
      }
      await tester.tap(find.byTooltip('Play note'));
      await pumpCaptureUi(tester);
      expect(audio.played, [file]);
      expect(find.byTooltip('Stop note'), findsOneWidget);
      audio.completed.add({'file': file, 'status': 'completed'});
      await tester.pump();
      expect(find.byTooltip('Play note'), findsOneWidget);
      audio.playError = PlatformException(code: 'recording');
      await tester.tap(find.byTooltip('Play note'));
      await pumpCaptureUi(tester);
      expect(
        find.text('End Delay before playing audio notes.'),
        findsOneWidget,
      );
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await tester.pump();
      expect(tester.takeException(), isNull);
      final stops = audio.stops;
      await tester.pageBack();
      await pumpCaptureUi(tester);
      expect(audio.stops, greaterThan(stops));
      expect(journal.rows.length, 3);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await audio.completed.close();
    },
  );
}
