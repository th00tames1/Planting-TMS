import 'dart:async';
import '../motion/motion_tracker.dart';
import 'field_location.dart';

/// Reconciles asynchronous sensors with the last durably accepted capture
/// state. Stop can cancel an in-flight motion permission request; a subsequent
/// Resume waits for that cancellation before issuing its own Start.
class CaptureSensors {
  CaptureSensors({
    required this.motion,
    required this.location,
    required this.onReading,
  });
  final MotionTracker motion;
  final FieldLocation location;
  final void Function(MotionReading) onReading;
  String? _desiredId;
  String? _requestedId;
  double? _stepLength;
  int _motionRevision = 0;
  int _attemptedMotionRevision = -1;
  int _locationRevision = 0;
  int _appliedLocationRevision = -1;
  bool _warming = false;
  bool _enableRequested = false;
  bool _closed = false;
  Future<void>? _motionWork;
  Future<void>? _locationWork;
  Future<void> _pauses = Future.value();

  void setRunning(String? sessionId, {double? stepLengthM}) {
    if (_closed) return;
    _desiredId = sessionId;
    _stepLength = stepLengthM;
    _motionRevision++;
    _locationRevision++;
    _warming = false;
    _enableRequested = false;
    if (_requestedId != null && sessionId != _requestedId) {
      // Do not queue behind Start: native pause also cancels its permission
      // request, which might otherwise remain open indefinitely.
      unawaited(_pause(_requestedId!));
    }
    _pumpMotion();
    _pumpLocation();
  }

  Future<void> warmUp({bool requestPermission = true}) {
    if (_closed) return Future.value();
    _warming = true;
    _enableRequested = _enableRequested || requestPermission;
    _locationRevision++;
    _pumpLocation();
    return _locationWork ?? Future.value();
  }

  void endWarmUp() {
    if (_closed) return;
    _warming = false;
    _enableRequested = false;
    _locationRevision++;
    _pumpLocation();
  }

  MotionReading _failed(String id) => MotionReading(
    sessionId: id,
    status: MotionStatus.error,
    steps: 0,
    source: MotionSource.unavailable,
    observedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
    gap: true,
    message: 'Walking recording could not update. Stop and resume to retry.',
  );

  Future<void> _pause(String id) {
    final operation = _pauses.then((_) async {
      MotionReading reading;
      try {
        reading = await motion.pause(sessionId: id);
      } catch (_) {
        reading = _failed(id);
      }
      if (!_closed) onReading(reading);
    });
    _pauses = operation;
    return operation;
  }

  Future<void> _awaitPauses() async {
    while (true) {
      final last = _pauses;
      await last;
      if (identical(last, _pauses)) return;
    }
  }

  void _pumpMotion() {
    if (_closed || _motionWork != null) return;
    _motionWork = _runMotion().whenComplete(() {
      _motionWork = null;
      if (!_closed &&
          _desiredId != null &&
          _attemptedMotionRevision != _motionRevision) {
        _pumpMotion();
      }
    });
  }

  Future<void> _runMotion() async {
    while (!_closed) {
      await _awaitPauses();
      final id = _desiredId;
      if (_closed ||
          id == null ||
          _attemptedMotionRevision == _motionRevision) {
        return;
      }
      final revision = _motionRevision;
      _attemptedMotionRevision = revision;
      _requestedId = id;
      MotionReading reading;
      try {
        reading = await motion.start(sessionId: id, stepLengthM: _stepLength);
      } catch (_) {
        reading = _failed(id);
      }
      if (_closed) return;
      onReading(reading);
      if (revision == _motionRevision && id == _desiredId) return;
      // A late Start response can arrive after Stop's acknowledgement. Close
      // that old request before starting whichever session is now desired.
      await _pause(id);
    }
  }

  void _pumpLocation() {
    if (_closed || _locationWork != null) return;
    _locationWork = _runLocation().whenComplete(() {
      _locationWork = null;
      if (!_closed && _appliedLocationRevision != _locationRevision) {
        _pumpLocation();
      }
    });
  }

  Future<void> _runLocation() async {
    while (!_closed && _appliedLocationRevision != _locationRevision) {
      final revision = _locationRevision;
      final enable = _enableRequested;
      _enableRequested = false;
      try {
        if (enable) {
          await location.enable();
        } else if (_desiredId != null || _warming) {
          await location.start();
        } else {
          await location.stop();
        }
      } catch (_) {
        // FieldLocation publishes transport failures as explicit unavailable
        // states. A test/custom source must not break time/CSV capture either.
      }
      _appliedLocationRevision = revision;
    }
  }

  Future<void> get settled async {
    while (true) {
      final motionWork = _motionWork;
      final locationWork = _locationWork;
      final pauses = _pauses;
      await Future.wait([
        if (motionWork != null) motionWork,
        if (locationWork != null) locationWork,
        pauses,
      ]);
      if (_motionWork == null &&
          _locationWork == null &&
          identical(pauses, _pauses)) {
        return;
      }
    }
  }

  Future<void> close({required bool stop}) async {
    if (_closed) return;
    if (stop) {
      setRunning(null);
      await settled;
    }
    _closed = true;
  }
}
