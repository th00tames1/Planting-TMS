import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class FieldLocation extends ChangeNotifier {
  static const _methods = MethodChannel('field_tms/location');
  static const _events = EventChannel('field_tms/location_events');
  Map<String, dynamic> _latest = {'status': 'off'};
  StreamSubscription<Object?>? _subscription;
  String bootId = 'process-${DateTime.now().microsecondsSinceEpoch}';
  bool _disposed = false;
  String? _publisher;
  int _serial = -1;

  Future<void> initialize() async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      _latest = {'status': 'unavailable'};
      return;
    }
    final info = await _methods.invokeMapMethod<String, dynamic>('clockInfo');
    final id = info?['bootId'];
    if (id is! String || id.isEmpty) {
      throw StateError('Device clock identity is unavailable.');
    }
    bootId = id;
    _subscription = _events.receiveBroadcastStream().listen((raw) {
      if (raw is Map) _accept(Map<String, dynamic>.from(raw));
    }, onError: (Object error) => _accept({'status': 'error'}));
  }

  void _accept(Map<String, dynamic> value) {
    if (_disposed) return;
    final publisher = value['publisher'] as String?;
    final serial = value['serial'] as int?;
    if (publisher != null && serial != null) {
      if (_publisher != null && publisher != _publisher) {
        _latest = {'status': 'connection_changed'};
        notifyListeners();
        return;
      }
      if (serial <= _serial) return;
      _publisher = publisher;
      _serial = serial;
    } else if (_publisher != null) {
      // Local transport failures may remove a fix, but an unordered response
      // must never overwrite a newer native location.
      if (value['latitude'] != null) return;
    }
    final lat = value['latitude'];
    final lon = value['longitude'];
    final accuracy = value['accuracyM'];
    final fixMs = value['fixMonoMs'];
    final fixUtc = value['fixUtc'];
    if (lat != null && (lat is! num || !lat.isFinite || lat.abs() > 90) ||
        lon != null && (lon is! num || !lon.isFinite || lon.abs() > 180) ||
        accuracy != null &&
            (accuracy is! num || !accuracy.isFinite || accuracy < 0) ||
        fixMs != null && (fixMs is! int || fixMs < 0) ||
        value['status'] == 'fresh' &&
            (lat == null ||
                lon == null ||
                accuracy == null ||
                fixMs == null ||
                fixUtc is! String ||
                DateTime.tryParse(fixUtc) == null)) {
      _latest = {'status': 'invalid'};
    } else {
      _latest = value;
      if (value['mock'] == true) _latest['status'] = 'simulated';
    }
    notifyListeners();
  }

  /// A boundary never waits for GPS. Its actual fix age and accuracy travel
  /// with the coordinates; a stale fix is retained and labeled, not relabeled.
  Map<String, dynamic> at(int monoMs) {
    final value = Map<String, dynamic>.from(_latest);
    final fixMs = value['fixMonoMs'] as int?;
    if (fixMs != null) {
      final age = monoMs - fixMs;
      value['ageMs'] = age;
      if (age < 0) {
        value['status'] = 'clock_mismatch';
      } else if (age > 15000 &&
          value['latitude'] != null &&
          value['status'] != 'simulated') {
        value['status'] = 'stale';
      }
    }
    return value;
  }

  Future<void> enable() => _invoke('enable');
  Future<void> start() => _invoke('start');
  Future<void> stop() => _invoke('stop');
  Future<void> _invoke(String method) async {
    if (kIsWeb) return;
    try {
      final value = await _methods.invokeMapMethod<String, dynamic>(method);
      if (value != null) _accept(value);
    } catch (_) {
      _accept({'status': 'unavailable'});
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
