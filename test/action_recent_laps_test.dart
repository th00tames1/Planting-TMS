import 'dart:async';

import 'package:field_tms/actions/action_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'action_capture_test.dart' show MemoryJournal, TestClock, recorder;
import 'capture_test_pump.dart';

Finder lapRows() => find.byWidgetPredicate(
  (widget) =>
      widget is Padding &&
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('recent-interval-'),
);

void main() {
  testWidgets('latest activity leads two compact live laps on a short screen', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final clock = TestClock();
    final journal = MemoryJournal();
    final c = recorder(journal, clock);
    await tester.pumpWidget(ActionCaptureApp(recorder: c));
    await pumpCaptureUi(tester);
    for (var cycle = 1; cycle <= 5; cycle++) {
      await tester.tap(find.byKey(const ValueKey('activity-Planting')));
      await pumpCaptureUi(tester);
      clock.now += 1100;
      await tester.tap(find.byKey(const ValueKey('activity-Walking')));
      await pumpCaptureUi(tester);
      clock.now += 500;
    }
    await tester.pump(const Duration(milliseconds: 16));
    expect(c.cycle, 5);
    expect(lapRows().evaluate().length, greaterThanOrEqualTo(2));
    final live = find.byKey(const ValueKey('recent-interval-current-activity'));
    final previous = find.byKey(const ValueKey('recent-interval-9'));
    expect(
      tester.getTopLeft(live).dy,
      lessThan(tester.getTopLeft(previous).dy),
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('recent-label-current-activity')),
          )
          .data,
      'Walking',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('recent-label-9'))).data,
      'Planting',
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('recent-time-current-activity')),
          )
          .data,
      '00:00.50',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('recent-time-9'))).data,
      '00:01.10',
    );
    for (final id in ['current-activity', '9']) {
      expect(
        tester.getCenter(find.byKey(ValueKey('recent-label-$id'))).dy,
        closeTo(
          tester.getCenter(find.byKey(ValueKey('recent-cycle-$id'))).dy,
          1,
        ),
        reason: 'Activity and Cycle stay on the same line.',
      );
    }
    final savedText = tester.widget(
      find.byKey(const ValueKey('recent-time-9')),
    );
    final writes = journal.rows.length;
    clock.now += 230;
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('recent-time-current-activity')),
          )
          .data,
      '00:00.73',
    );
    expect(
      identical(
        savedText,
        tester.widget(find.byKey(const ValueKey('recent-time-9'))),
      ),
      true,
    );
    expect(journal.rows.length, writes);
    expect(find.byType(Scrollable), findsNothing);
    expect(tester.takeException(), isNull);
    await c.stop();
    await pumpCaptureUi(tester);
    expect(lapRows().evaluate().length, greaterThanOrEqualTo(2));
    expect(find.byKey(const ValueKey('recent-interval-10')), findsOneWidget);
    expect(find.byKey(const ValueKey('recent-interval-9')), findsOneWidget);
    expect(live, findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'queued clicks preview the latest two laps and rollback on failure',
    (tester) async {
      final clock = TestClock();
      final journal = MemoryJournal();
      final c = recorder(journal, clock);
      await tester.pumpWidget(ActionCaptureApp(recorder: c));
      await pumpCaptureUi(tester);
      await tester.tap(find.byKey(const ValueKey('activity-Planting')));
      await pumpCaptureUi(tester);
      clock.now = 2000;
      journal.barrier = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('activity-Walking')));
      await tester.pump();
      clock.now = 3000;
      await tester.tap(find.byKey(const ValueKey('activity-Planting')));
      await tester.pump();
      expect(lapRows().evaluate().length, greaterThanOrEqualTo(2));
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('recent-label-current-activity')),
            )
            .data,
        'Planting',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('recent-label-outgoing')))
            .data,
        'Walking',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('recent-time-outgoing')))
            .data,
        '00:01.00',
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('recent-cycle-current-activity')),
            )
            .data,
        '· Cycle 2',
      );
      expect(c.cycle, 1);
      journal.barrier!.complete();
      await pumpCaptureUi(tester);
      expect(c.cycle, 2);
      expect(find.byKey(const ValueKey('recent-interval-2')), findsOneWidget);
      clock.now = 4000;
      journal.barrier = Completer<void>();
      journal.fail = true;
      await tester.tap(find.byKey(const ValueKey('activity-Walking')));
      await tester.pump();
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('recent-label-current-activity')),
            )
            .data,
        'Walking',
      );
      journal.barrier!.complete();
      await pumpCaptureUi(tester);
      expect(find.text('Retry save'), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('recent-label-current-activity')),
            )
            .data,
        'Planting',
      );
      expect(find.byKey(const ValueKey('recent-interval-2')), findsOneWidget);
      expect(c.cycle, 2);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
