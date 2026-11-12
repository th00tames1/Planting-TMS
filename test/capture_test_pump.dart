import 'package:flutter_test/flutter_test.dart';

/// A running stopwatch intentionally schedules another display frame, so it
/// never settles. Pump capture/route transitions for a finite duration instead.
Future<void> pumpCaptureUi(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}
