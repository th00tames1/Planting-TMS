import 'dart:ffi';
import 'dart:io';

import 'capture_clock_types.dart';

CaptureClock createPlatformCaptureClock() {
  if (Platform.isIOS) return _IosContinuousClock();
  if (!Platform.isAndroid) return StopwatchCaptureClock();
  try {
    return _AndroidBoottimeCaptureClock();
  } catch (error, stack) {
    Error.throwWithStackTrace(
      StateError('Android elapsed-realtime clock could not start: $error'),
      stack,
    );
  }
}

final class _MachTimebase extends Struct {
  @Uint32()
  external int numerator;
  @Uint32()
  external int denominator;
}

/// mach_continuous_time includes device sleep and shares the same boot epoch
/// as native Core Location boundary age measurements.
final class _IosContinuousClock implements CaptureClock {
  _IosContinuousClock() {
    final library = DynamicLibrary.process();
    _read = library.lookupFunction<Uint64 Function(), int Function()>(
      'mach_continuous_time',
      isLeaf: true,
    );
    final allocate = library.lookupFunction<_NativeMalloc, _Malloc>('malloc');
    final free = library
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('free');
    final info = allocate(sizeOf<_MachTimebase>()).cast<_MachTimebase>();
    if (info == nullptr) throw StateError('Could not allocate clock timebase.');
    try {
      final result = library
          .lookupFunction<
            Int32 Function(Pointer<_MachTimebase>),
            int Function(Pointer<_MachTimebase>)
          >('mach_timebase_info')(info);
      if (result != 0 || info.ref.denominator == 0 || info.ref.numerator == 0) {
        throw StateError('Device continuous clock is unavailable.');
      }
      _millisecondsPerTick =
          info.ref.numerator / info.ref.denominator / 1000000;
    } finally {
      free(info.cast<Void>());
    }
  }
  late final int Function() _read;
  late final double _millisecondsPerTick;
  @override
  int get monotonicMs => (_read() * _millisecondsPerTick).floor();
  @override
  DateTime get wallTime => DateTime.now();
}

// Public Android Bionic ABI: time_t and long are pointer-sized on supported
// Android ILP32/LP64 ABIs. This is not the Windows C long ABI.
// https://android.googlesource.com/platform/bionic/+/refs/heads/main/libc/include/bits/timespec.h
final class _Timespec extends Struct {
  @IntPtr()
  external int seconds;

  @IntPtr()
  external int nanoseconds;
}

typedef _NativeClockGettime = Int32 Function(Int32, Pointer<_Timespec>);
typedef _ClockGettime = int Function(int, Pointer<_Timespec>);
typedef _NativeMalloc = Pointer<Void> Function(UintPtr);
typedef _Malloc = Pointer<Void> Function(int);

final class _LibcClock {
  _LibcClock() : library = DynamicLibrary.open('libc.so');

  final DynamicLibrary library;
  late final _ClockGettime read = library
      .lookupFunction<_NativeClockGettime, _ClockGettime>(
        'clock_gettime',
        isLeaf: true,
      );
  late final _Malloc allocate = library.lookupFunction<_NativeMalloc, _Malloc>(
    'malloc',
  );
  late final Pointer<NativeFinalizerFunction> freePointer = library
      .lookup<NativeFinalizerFunction>('free');
  late final void Function(Pointer<Void>) free = freePointer
      .asFunction<void Function(Pointer<Void>)>();
}

/// One isolate owns each clock and its single reusable native buffer. There is
/// no channel round trip, timer, per-read allocation, or retained sample list.
final class _AndroidBoottimeCaptureClock implements CaptureClock, Finalizable {
  _AndroidBoottimeCaptureClock._(this._sample);

  static final _libc = _LibcClock();
  static final _finalizer = NativeFinalizer(_libc.freePointer);
  static const _clockBoottime = 7;
  final Pointer<_Timespec> _sample;

  factory _AndroidBoottimeCaptureClock() {
    final size = sizeOf<_Timespec>();
    final pointer = _libc.allocate(size).cast<_Timespec>();
    if (pointer == nullptr) {
      throw StateError('Android elapsed-realtime clock allocation failed.');
    }
    final clock = _AndroidBoottimeCaptureClock._(pointer);
    try {
      // Verify the real native path before the app accepts a measurement.
      clock._readMilliseconds();
      _finalizer.attach(clock, pointer.cast<Void>(), externalSize: size);
      return clock;
    } catch (_) {
      _libc.free(pointer.cast<Void>());
      rethrow;
    }
  }

  @override
  int get monotonicMs => _readMilliseconds();

  int _readMilliseconds() {
    final result = _libc.read(_clockBoottime, _sample);
    validateBoottimeResult(result);
    return boottimeMilliseconds(_sample.ref.seconds, _sample.ref.nanoseconds);
  }

  @override
  DateTime get wallTime => DateTime.now();
}

/// Kept separate from FFI so error and precision boundaries can be tested on
/// the host. Failed calls must not read an uninitialized native timespec.
void validateBoottimeResult(int result) {
  if (result != 0) {
    throw StateError(
      'clock_gettime(CLOCK_BOOTTIME) failed with status $result.',
    );
  }
}

int boottimeMilliseconds(int seconds, int nanoseconds) {
  if (seconds < 0 || nanoseconds < 0 || nanoseconds >= 1000000000) {
    throw StateError(
      'Android elapsed-realtime clock returned an invalid time.',
    );
  }
  final fractionalMs = nanoseconds ~/ 1000000;
  const maxMilliseconds = 0x7fffffffffffffff;
  if (seconds > (maxMilliseconds - fractionalMs) ~/ 1000) {
    throw StateError(
      'Android elapsed-realtime clock exceeded the integer range.',
    );
  }
  return seconds * 1000 + fractionalMs;
}
