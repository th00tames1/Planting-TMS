import 'capture_clock_stub.dart'
    if (dart.library.io) 'capture_clock_native.dart'
    as platform;
import 'capture_clock_types.dart';

export 'capture_clock_types.dart' show CaptureClock, StopwatchCaptureClock;

/// Android initialization failures propagate instead of choosing a sleep-blind
/// fallback. The application must report the failure before accepting capture.
CaptureClock createDefaultCaptureClock() =>
    platform.createPlatformCaptureClock();
