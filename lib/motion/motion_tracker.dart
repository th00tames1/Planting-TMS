import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum MotionStatus {
  idle,
  running,
  paused,
  permissionDenied,
  unavailable,
  error,
}

enum MotionSource {
  androidStepCounter('android_step_counter'),
  iosPedometer('ios_pedometer'),
  unavailable('unavailable');

  const MotionSource(this.wireName);
  final String wireName;
}

/// Native measurements and their availability. Distance is never synthesized
/// here: a null native distance remains null in memory and persisted snapshots.
@immutable
class MotionReading {
  factory MotionReading({
    required MotionStatus status,
    required int steps,
    required MotionSource source,
    required int observedAtEpochMs,
    String? observationEpoch,
    int? observationSequence,
    String? sessionId,
    double? distanceM,
    double? stepLengthM,
    bool estimated = true,
    bool gap = false,
    String? message,
  }) {
    if (sessionId != null && sessionId.trim().isEmpty) {
      throw ArgumentError.value(sessionId, 'sessionId', 'Must not be empty');
    }
    if (steps < 0) throw ArgumentError.value(steps, 'steps');
    if (observedAtEpochMs < 0) {
      throw ArgumentError.value(observedAtEpochMs, 'observedAtEpochMs');
    }
    if (!validObservationOrder(observationEpoch, observationSequence)) {
      throw ArgumentError('Invalid motion observation ordering pair.');
    }
    _validateLength(distanceM, 'distanceM');
    _validateLength(stepLengthM, 'stepLengthM', positive: true);
    if (!estimated) {
      throw ArgumentError.value(estimated, 'estimated', 'Must be true');
    }
    final unavailable =
        source == MotionSource.unavailable ||
        status == MotionStatus.permissionDenied ||
        status == MotionStatus.unavailable ||
        status == MotionStatus.error;
    if (unavailable && distanceM != null) {
      throw ArgumentError.value(
        distanceM,
        'distanceM',
        'Unavailable measurements must have null distance',
      );
    }
    if (status == MotionStatus.running && source == MotionSource.unavailable) {
      throw ArgumentError.value(source, 'source', 'Running requires a source');
    }
    return MotionReading._(
      sessionId: sessionId,
      status: status,
      steps: steps,
      distanceM: distanceM,
      stepLengthM: stepLengthM,
      source: source,
      estimated: estimated,
      observedAtEpochMs: observedAtEpochMs,
      observationEpoch: observationEpoch,
      observationSequence: observationSequence,
      gap: gap,
      message: message,
    );
  }

  const MotionReading._({
    required this.sessionId,
    required this.status,
    required this.steps,
    required this.distanceM,
    required this.stepLengthM,
    required this.source,
    required this.estimated,
    required this.observedAtEpochMs,
    required this.observationEpoch,
    required this.observationSequence,
    required this.gap,
    required this.message,
  });

  /// An initial state with no sensor observation, useful before initialization.
  const MotionReading.unavailable()
    : sessionId = null,
      status = MotionStatus.unavailable,
      steps = 0,
      distanceM = null,
      stepLengthM = null,
      source = MotionSource.unavailable,
      estimated = true,
      observedAtEpochMs = 0,
      observationEpoch = null,
      observationSequence = null,
      gap = false,
      message = 'Walking measurement is unavailable.';

  factory MotionReading.fromMap(Map<Object?, Object?> map) {
    final status = MotionStatus.values
        .where((status) => status.name == map['status'])
        .firstOrNull;
    final source = MotionSource.values
        .where((source) => source.wireName == map['source'])
        .firstOrNull;
    if (status == null || source == null) {
      throw const FormatException('Unknown motion status or source.');
    }
    if (map['steps'] is! int || map['observedAtEpochMs'] is! int) {
      throw const FormatException(
        'Motion counts and timestamp must be integers.',
      );
    }
    if (map['estimated'] is! bool || map['gap'] is! bool) {
      throw const FormatException('Missing motion availability flags.');
    }
    if ((map['sessionId'] != null && map['sessionId'] is! String) ||
        (map['message'] != null && map['message'] is! String) ||
        (map['observationEpoch'] != null &&
            map['observationEpoch'] is! String) ||
        (map['observationSequence'] != null &&
            map['observationSequence'] is! int)) {
      throw const FormatException('Invalid motion session or message.');
    }
    try {
      return MotionReading(
        sessionId: map['sessionId'] as String?,
        status: status,
        steps: map['steps'] as int,
        distanceM: _number(map['distanceM'], 'distanceM'),
        stepLengthM: _number(map['stepLengthM'], 'stepLengthM'),
        source: source,
        estimated: map['estimated'] as bool,
        observedAtEpochMs: map['observedAtEpochMs'] as int,
        observationEpoch: map['observationEpoch'] as String?,
        observationSequence: map['observationSequence'] as int?,
        gap: map['gap'] as bool,
        message: map['message'] as String?,
      );
    } on ArgumentError {
      throw const FormatException('Invalid values in motion snapshot.');
    }
  }

  final String? sessionId;
  final MotionStatus status;
  final int steps;
  final double? distanceM;
  final double? stepLengthM;
  final MotionSource source;
  final bool estimated;
  final int observedAtEpochMs;

  /// Native owner identity and serial capture order, independent of wall time.
  /// Both are absent only for older bridges and persisted legacy readings.
  final String? observationEpoch;
  final int? observationSequence;
  final bool gap;
  final String? message;

  /// The same schema is used on the platform channel and in local storage.
  Map<String, dynamic> toMap() => Map<String, dynamic>.unmodifiable({
    'sessionId': sessionId,
    'status': status.name,
    'steps': steps,
    'distanceM': distanceM,
    'stepLengthM': stepLengthM,
    'source': source.wireName,
    'estimated': estimated,
    'observedAtEpochMs': observedAtEpochMs,
    if (observationEpoch != null) 'observationEpoch': observationEpoch,
    if (observationSequence != null) 'observationSequence': observationSequence,
    'gap': gap,
    'message': message,
  });

  // The same exact integer range is available on native Dart and JavaScript.
  static const maxObservationSequence = 9007199254740991;

  static bool validObservationOrder(String? epoch, int? sequence) =>
      epoch == null && sequence == null ||
      epoch != null &&
          epoch.isNotEmpty &&
          epoch == epoch.trim() &&
          epoch.length <= 128 &&
          sequence != null &&
          sequence > 0 &&
          sequence <= maxObservationSequence;

  static double? _number(Object? value, String field) {
    if (value == null) return null;
    if (value is! num) throw FormatException('$field must be numeric or null.');
    return value.toDouble();
  }

  static void _validateLength(
    double? value,
    String field, {
    bool positive = false,
  }) {
    if (value != null &&
        (!value.isFinite || (positive ? value <= 0 : value < 0))) {
      throw ArgumentError.value(value, field, 'Must be finite and nonnegative');
    }
  }
}

abstract class MotionTracker {
  Future<MotionReading> read();
  Future<MotionReading> start({required String sessionId, double? stepLengthM});
  Future<MotionReading> pause({required String sessionId});
  Future<MotionReading> setStepLength({double? stepLengthM});
  Stream<MotionReading> get readings;
  Future<void> dispose();
}

MotionTracker createDefaultMotionTracker({
  TargetPlatform? platform,
  bool? isWeb,
}) {
  if (isWeb ?? kIsWeb) {
    return UnavailableMotionTracker(
      message: 'Walking measurement is unavailable in this browser.',
    );
  }
  switch (platform ?? defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return NativeMotionTracker();
    default:
      return UnavailableMotionTracker(
        message: 'Walking measurement is available on Android and iOS.',
      );
  }
}

class NativeMotionTracker implements MotionTracker {
  NativeMotionTracker({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    int Function()? nowEpochMs,
  }) : _methods = methodChannel ?? const MethodChannel(methodChannelName),
       _events = eventChannel ?? const EventChannel(eventChannelName),
       _nowEpochMs = nowEpochMs ?? _now {
    _readings = StreamController<MotionReading>.broadcast(
      onListen: _listenToEvents,
    );
  }

  static const methodChannelName = 'field_tms/motion';
  static const eventChannelName = 'field_tms/motion_events';

  final MethodChannel _methods;
  final EventChannel _events;
  final int Function() _nowEpochMs;
  late final StreamController<MotionReading> _readings;
  Future<void>? _eventActivation;
  bool _eventHandlerInstalled = false;
  bool _eventActive = false;
  bool _disposed = false;
  MotionReading? _lastReading;
  String? _observationEpoch;
  int _highestObservationSequence = 0;
  bool _ownerChanged = false;

  @override
  Stream<MotionReading> get readings => _readings.stream;

  @override
  Future<MotionReading> read() => _invoke('read');

  @override
  Future<MotionReading> start({
    required String sessionId,
    double? stepLengthM,
  }) {
    _validateSession(sessionId);
    MotionReading._validateLength(stepLengthM, 'stepLengthM', positive: true);
    return _invoke(
      'start',
      arguments: {'sessionId': sessionId, 'stepLengthM': stepLengthM},
      sessionId: sessionId,
    );
  }

  @override
  Future<MotionReading> pause({required String sessionId}) {
    _validateSession(sessionId);
    return _invoke(
      'pause',
      arguments: {'sessionId': sessionId},
      sessionId: sessionId,
    );
  }

  @override
  Future<MotionReading> setStepLength({double? stepLengthM}) {
    MotionReading._validateLength(stepLengthM, 'stepLengthM', positive: true);
    return _invoke('setStepLength', arguments: {'stepLengthM': stepLengthM});
  }

  Future<MotionReading> _invoke(
    String method, {
    Map<String, Object?>? arguments,
    String? sessionId,
  }) async {
    _checkOpen();
    try {
      final raw = await _methods.invokeMethod<Object?>(method, arguments);
      final reading = _decode(raw);
      if (_acceptOrder(reading)) return reading;
      // A method response can arrive after a newer event or method response.
      // Return the accepted state instead of exposing an older raw counter.
      return _lastReading!;
    } catch (error) {
      return _failure(error, sessionId: sessionId);
    }
  }

  MotionReading _decode(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Expected a motion snapshot.');
    }
    return MotionReading.fromMap(raw);
  }

  bool _acceptOrder(MotionReading reading) {
    if (_ownerChanged) throw const _MotionOwnerChanged();
    final epoch = reading.observationEpoch;
    if (epoch == null) {
      if (_observationEpoch != null) {
        throw const FormatException('Motion ordering metadata disappeared.');
      }
    } else {
      if (_observationEpoch != null && epoch != _observationEpoch) {
        _ownerChanged = true;
        throw const _MotionOwnerChanged();
      }
      _observationEpoch ??= epoch;
      final sequence = reading.observationSequence!;
      if (sequence <= _highestObservationSequence) return false;
      _highestObservationSequence = sequence;
    }
    _lastReading = reading;
    return true;
  }

  void _listenToEvents() {
    if (_disposed || _eventActivation != null) return;
    _eventActivation = _activateEvents();
    unawaited(_eventActivation);
  }

  Future<void> _activateEvents() async {
    // EventChannel.receiveBroadcastStream reports a missing native plugin via
    // FlutterError, outside its stream. Handle its documented listen/cancel
    // protocol directly so an unavailable sensor remains a normal data state.
    try {
      _events.binaryMessenger.setMessageHandler(_events.name, (reply) async {
        if (_disposed) return null;
        if (reply == null) {
          _publish(
            _failure(MissingPluginException('Motion event stream ended.')),
          );
        } else {
          try {
            final reading = _decode(_events.codec.decodeEnvelope(reply));
            if (_acceptOrder(reading)) _publish(reading);
          } catch (error) {
            _publish(_failure(error));
          }
        }
        return null;
      });
      _eventHandlerInstalled = true;
      await _eventMethods.invokeMethod<void>('listen');
      _eventActive = true;
    } catch (error) {
      if (_eventHandlerInstalled) {
        _events.binaryMessenger.setMessageHandler(_events.name, null);
        _eventHandlerInstalled = false;
      }
      _publish(_failure(error));
    }
  }

  MethodChannel get _eventMethods =>
      MethodChannel(_events.name, _events.codec, _events.binaryMessenger);

  void _publish(MotionReading reading) {
    if (_disposed) return;
    _lastReading = reading;
    _readings.add(reading);
  }

  MotionReading _failure(Object error, {String? sessionId}) {
    var status = MotionStatus.error;
    var message = 'Could not read walking data. Try again.';
    if (_ownerChanged || error is _MotionOwnerChanged) {
      message =
          'Walking connection changed. Close and reopen the app to reconnect.';
    } else if (error is MissingPluginException) {
      status = MotionStatus.unavailable;
      message = 'Walking measurement is unavailable in this app build.';
    } else if (error is PlatformException) {
      final code = error.code.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
      if (code.contains('permission') ||
          code == 'denied' ||
          code == 'notauthorized') {
        status = MotionStatus.permissionDenied;
        message = 'Motion permission is required to measure walking.';
      } else if (code.contains('unavailable') ||
          code.contains('unsupported') ||
          code == 'notsupported' ||
          code == 'nosensor') {
        status = MotionStatus.unavailable;
        message = 'Walking measurement is unavailable on this device.';
      }
    } else if (error is FormatException || error is TypeError) {
      message = 'Received invalid walking data. Try again.';
    }
    final previous = _lastReading;
    final sameSession = sessionId == null || previous?.sessionId == sessionId;
    return MotionReading(
      sessionId: sessionId ?? previous?.sessionId,
      status: status,
      steps: sameSession ? previous?.steps ?? 0 : 0,
      distanceM: null,
      stepLengthM: sameSession ? previous?.stepLengthM : null,
      source: MotionSource.unavailable,
      observedAtEpochMs: _nowEpochMs(),
      gap:
          _ownerChanged ||
          previous?.status == MotionStatus.running ||
          previous?.gap == true,
      message: message,
    );
  }

  void _checkOpen() {
    if (_disposed) throw StateError('Motion tracker has been disposed.');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _eventActivation;
    if (_eventHandlerInstalled) {
      _events.binaryMessenger.setMessageHandler(_events.name, null);
      _eventHandlerInstalled = false;
    }
    if (_eventActive) {
      try {
        await _eventMethods.invokeMethod<void>('cancel');
      } catch (_) {
        // A missing/disconnected native stream has no remaining subscription.
      }
    }
    await _readings.close();
  }
}

class _MotionOwnerChanged implements Exception {
  const _MotionOwnerChanged();
}

class UnavailableMotionTracker implements MotionTracker {
  UnavailableMotionTracker({
    this.message = 'Walking measurement is unavailable.',
    int Function()? nowEpochMs,
  }) : _nowEpochMs = nowEpochMs ?? _now;

  final String message;
  final int Function() _nowEpochMs;
  final StreamController<MotionReading> _readings =
      StreamController<MotionReading>.broadcast();
  String? _sessionId;
  double? _stepLengthM;
  bool _disposed = false;

  @override
  Stream<MotionReading> get readings => _readings.stream;

  @override
  Future<MotionReading> read() async => _reading();

  @override
  Future<MotionReading> start({
    required String sessionId,
    double? stepLengthM,
  }) async {
    _validateSession(sessionId);
    MotionReading._validateLength(stepLengthM, 'stepLengthM', positive: true);
    _sessionId = sessionId;
    _stepLengthM = stepLengthM;
    return _reading();
  }

  @override
  Future<MotionReading> pause({required String sessionId}) async {
    _validateSession(sessionId);
    _sessionId = sessionId;
    return _reading();
  }

  @override
  Future<MotionReading> setStepLength({double? stepLengthM}) async {
    MotionReading._validateLength(stepLengthM, 'stepLengthM', positive: true);
    _stepLengthM = stepLengthM;
    return _reading();
  }

  MotionReading _reading() {
    if (_disposed) throw StateError('Motion tracker has been disposed.');
    return MotionReading(
      sessionId: _sessionId,
      status: MotionStatus.unavailable,
      steps: 0,
      distanceM: null,
      stepLengthM: _stepLengthM,
      source: MotionSource.unavailable,
      observedAtEpochMs: _nowEpochMs(),
      message: message,
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _readings.close();
  }
}

void _validateSession(String sessionId) {
  if (sessionId.trim().isEmpty) {
    throw ArgumentError.value(sessionId, 'sessionId', 'Must not be empty');
  }
}

int _now() => DateTime.now().millisecondsSinceEpoch;
