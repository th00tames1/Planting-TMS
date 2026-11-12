import 'package:field_tms/clock/capture_clock.dart';
import 'package:field_tms/clock/capture_clock_native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'timespec conversion floors submillisecond fractions at a second boundary',
    () {
      expect(boottimeMilliseconds(0, 999999), 0);
      expect(boottimeMilliseconds(42, 999999999), 42999);
      expect(boottimeMilliseconds(43, 0), 43000);
    },
  );

  test(
    'long absolute uptime retains exact integer millisecond differences',
    () {
      final start = boottimeMilliseconds(2147483647, 123456789);
      final end = boottimeMilliseconds(2147512447, 124456789);
      expect(start, 2147483647123);
      expect(end - start, 28800001);
    },
  );

  test('failed native status is rejected before interpreting a sample', () {
    expect(() => validateBoottimeResult(-1), throwsStateError);
    expect(() => validateBoottimeResult(1), throwsStateError);
    expect(() => validateBoottimeResult(0), returnsNormally);
  });

  test('invalid timespec fields cannot become plausible elapsed time', () {
    expect(() => boottimeMilliseconds(-1, 0), throwsStateError);
    expect(() => boottimeMilliseconds(1, -1), throwsStateError);
    expect(() => boottimeMilliseconds(1, 1000000000), throwsStateError);
  });

  test('integer overflow cannot wrap uptime into a negative duration', () {
    expect(
      () => boottimeMilliseconds(0x7fffffffffffffff, 999999999),
      throwsStateError,
    );
  });

  test('platform factory supplies synchronous monotonic and wall readings', () {
    final before = DateTime.now();
    final clock = createDefaultCaptureClock();
    final first = clock.monotonicMs;
    final second = clock.monotonicMs;
    final wall = clock.wallTime;
    final after = DateTime.now();
    expect(first, greaterThanOrEqualTo(0));
    expect(second, greaterThanOrEqualTo(first));
    expect(wall.isBefore(before), isFalse);
    expect(wall.isAfter(after), isFalse);
  });
}
