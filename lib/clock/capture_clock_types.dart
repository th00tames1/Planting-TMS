/// Wall time is metadata and recovery input; live durations use [monotonicMs].
abstract class CaptureClock {
  int get monotonicMs;
  DateTime get wallTime;
}

/// Basic fallback for platforms whose runtime stopwatch has the required clock.
/// Android field capture uses CLOCK_BOOTTIME through the platform factory.
class StopwatchCaptureClock implements CaptureClock {
  final Stopwatch _stopwatch = Stopwatch()..start();

  @override
  int get monotonicMs => _stopwatch.elapsedMilliseconds;

  @override
  DateTime get wallTime => DateTime.now();
}
