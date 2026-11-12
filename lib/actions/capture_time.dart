String captureTime(int? milliseconds) {
  if (milliseconds == null) return '—';
  final value = milliseconds < 0 ? 0 : milliseconds;
  String two(int number) => number.toString().padLeft(2, '0');
  final seconds = two(value ~/ 1000 % 60);
  final hundredths = two(value ~/ 10 % 100);
  if (value >= 3600000) {
    return '${two(value ~/ 3600000)}:${two(value ~/ 60000 % 60)}:$seconds.$hundredths';
  }
  return '${two(value ~/ 60000)}:$seconds.$hundredths';
}
