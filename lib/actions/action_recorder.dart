import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../clock/capture_clock.dart';
import '../motion/motion_tracker.dart';
import 'action_journal.dart';
import 'field_location.dart';
import 'capture_sensors.dart';
import 'delay_audio.dart';

const fieldActions = [
  'Planting',
  'Walking',
  'Preparation',
  'Walk out',
  'Delay',
];
const delayReasons = [
  'Personal',
  'Operational',
  'Mechanical',
  'Administrative',
];

class ActionRecorder extends ChangeNotifier {
  ActionRecorder(
    this.journal, {
    CaptureClock? clock,
    FieldLocation? location,
    MotionTracker? motion,
    DelayAudio? audio,
  }) : clock = clock ?? createDefaultCaptureClock(),
       location = location ?? FieldLocation(),
       motion = motion ?? createDefaultMotionTracker(),
       audio = audio ?? DelayAudio();
  final ActionJournal journal;
  final CaptureClock clock;
  final FieldLocation location;
  final MotionTracker motion;
  final DelayAudio audio;
  String? _audioTarget;
  String audioStatus = 'off';
  Future<void> _audioWork = Future.value();
  int _audioBusy = 0;
  Future<void> get audioSettled => _audioWork;
  final ValueNotifier<int> ticks = ValueNotifier(0);
  final ValueNotifier<int> sensorTicks = ValueNotifier(0);
  Map<String, dynamic> _state = {};
  final List<Map<String, dynamic>> events = [];
  Future<void> _tail = Future.value();
  Timer? _gpsWarmup;
  int _gpsWarmupRevision = 0;
  StreamSubscription<MotionReading>? _motionSubscription;
  StreamSubscription<Map<String, dynamic>>? _audioSubscription;
  MotionReading _motion = const MotionReading.unavailable();
  Map<String, dynamic>? _retry;
  Object? error;
  bool _closed = false;
  bool _visible = true;
  bool _gpsPermissionRequested = false;
  int pending = 0;
  int _generation = 0;
  bool recovered = false;
  late final CaptureSensors _sensors = CaptureSensors(
    motion: motion,
    location: location,
    onReading: (reading) {
      if (_closed) return;
      _motion = reading;
      _sensorChanged();
    },
  );
  Future<void> get sensorsSettled => _sensors.settled;

  bool get running => _state['running'] == true;
  bool get shouldRefreshDisplay =>
      !_closed && _visible && !needsReview && (running || pending > 0);

  /// A view-frame signal only. Measurements and journal writes use captured
  /// continuous-clock boundaries, independently of how often a view redraws.
  void refreshDisplay() {
    if (shouldRefreshDisplay) ticks.value++;
  }

  bool get needsReview => running && _state['bootId'] != location.bootId;
  String get action {
    final saved = _state['action'] as String? ?? 'Walking';
    // A stopped legacy exclusive Delay needs a base activity for the new
    // overlay workflow. Its original intervals stay untouched in the journal.
    return !running && saved == 'Delay' ? 'Walking' : saved;
  }

  int get sequence => _state['seq'] as int? ?? 0;
  int get count => _state['count'] as int? ?? 0;
  int get delayCount => _state['delayCount'] as int? ?? 0;
  int get cycle => _state['cycle'] as int? ?? 0;
  int? get activityCycle =>
      (action == 'Planting' || action == 'Walking') && cycle > 0 ? cycle : null;
  int get activityDelayCount => _state['activeDelayCount'] as int? ?? 0;
  int displayDelayCount(String name) => running && name == action
      ? activityDelayCount
      : ((_state['lastDelayCounts'] as Map?)?[name] as int? ?? 0);

  bool canCapture(String name) {
    if (!fieldActions.take(4).contains(name)) return false;
    final returning = running && action == 'Walk out';
    return name == 'Preparation'
        ? returning
        : name == 'Walking'
        ? !returning
        : true;
  }

  bool get delayRunning => _state['delay'] is Map;
  String? get delayReason => (_state['delay'] as Map?)?['reason'] as String?;
  String? get lastDelayReason => _state['lastDelayReason'] as String?;
  int? get delayMs => delayRunning
      ? needsReview
            ? null
            : _delta(
                clock.monotonicMs,
                ((_state['delay'] as Map)['start'] as Map)['monoMs'] as int,
              )
      : _lastDuration('Delay');

  int? displayMs(String name) => name == 'Delay' && action != 'Delay'
      ? delayMs
      : running && action == name
      ? needsReview
            ? null
            : actionMs
      : name == 'Planting' || name == 'Walking'
      ? 0
      : _lastDuration(name);

  int? completedActivityMs(String name) {
    final totals = _state['activityTotalsMs'] as Map?;
    return totals == null ? 0 : totals[name] as int?;
  }

  int? cumulativeActivityMs(String name) {
    final completed = completedActivityMs(name);
    if (completed == null || running && action == name && needsReview) {
      return null;
    }
    return completed + (running && action == name ? actionMs : 0);
  }

  Future<void> _restoreActivityTotals() async {
    if (_state.isEmpty) return;
    final names = fieldActions.take(4);
    final saved = _state['activityTotalsMs'] as Map?;
    if (saved != null && names.every(saved.containsKey)) return;
    final totals = <String, int?>{for (final name in names) name: 0};
    String? cursor;
    var sameStudy = true;
    do {
      final page = await readActionPage(
        journal,
        cursor: cursor,
        maxSequence: sequence,
      );
      for (final event in page.events) {
        if ((event['state'] as Map)['studyId'] != studyId) {
          sameStudy = false;
          break;
        }
        final interval = event['closed'] as Map?;
        final name = interval?['action'];
        if (!totals.containsKey(name)) continue;
        final duration = interval?['durationMs'] as int?;
        final previous = totals[name];
        totals[name as String] = previous == null || duration == null
            ? null
            : previous + duration;
      }
      cursor = page.nextCursor;
    } while (sameStudy && cursor != null);
    // One upgrade scan, in bounded pages. The next normal boundary persists
    // this compact cache; opening history never rewrites earlier CSV records.
    _state['activityTotalsMs'] = totals;
  }

  Future<void> _restoreRecentIntervals() async {
    final expected = (count + delayCount).clamp(0, 12);
    if (recentIntervals.length >= expected) return;
    final intervals = <Map<String, dynamic>>[];
    String? cursor;
    var sameStudy = true;
    do {
      final page = await readActionPage(
        journal,
        cursor: cursor,
        maxSequence: sequence,
      );
      for (final event in page.events) {
        if ((event['state'] as Map)['studyId'] != studyId) {
          sameStudy = false;
          break;
        }
        for (final key in ['closed', 'delayClosed']) {
          final interval = event[key] as Map?;
          if (interval == null) continue;
          intervals.add({
            for (final key in [
              'number',
              'action',
              'durationMs',
              'reason',
              'cycle',
              'delayCount',
              'ordinal',
            ])
              key: interval[key],
            'overlap': key == 'delayClosed',
          });
          if (intervals.length >= expected) break;
        }
        if (intervals.length >= expected) break;
      }
      cursor = page.nextCursor;
    } while (sameStudy && cursor != null && intervals.length < expected);
    _state['recentIntervals'] = intervals;
  }

  int? _lastDuration(String name) {
    final durations = _state['lastDurations'] as Map?;
    if (durations != null && durations.containsKey(name)) {
      return durations[name] as int?;
    }
    for (final event in events.reversed) {
      if ((event['state'] as Map)['studyId'] != studyId) break;
      final closed = name == 'Delay' && event['delayClosed'] != null
          ? event['delayClosed'] as Map
          : event['closed'] as Map?;
      if (closed?['action'] == name) return closed!['durationMs'] as int?;
    }
    return 0;
  }

  List<Map<String, dynamic>> get recentIntervals {
    final saved = _state['recentIntervals'] as List?;
    if (saved != null) {
      return saved
          .map((value) => Map<String, dynamic>.from(value as Map))
          .toList();
    }
    final result = <Map<String, dynamic>>[];
    for (final event in events.reversed) {
      final saved = event['state'] as Map;
      if (saved['studyId'] != studyId) break;
      for (final key in ['closed', 'delayClosed']) {
        final interval = event[key] as Map?;
        if (interval == null) continue;
        result.add({
          ...Map<String, dynamic>.from(interval),
          'number': interval['number'] ?? saved['count'],
          'overlap': key == 'delayClosed',
        });
      }
      if (result.length >= 12) break;
    }
    return result.take(12).toList();
  }

  String get studyId => _state['studyId'] as String? ?? '';
  String get title => _state['title'] as String? ?? 'Field study';
  bool get canReset => count > 0 || _state['audioCleanupStudyId'] != null;
  MotionReading get walking => _motion;
  bool get hasCurrentWalking => _motion.sessionId == 'actions-$studyId';
  Map<String, dynamic> get gps => location.at(clock.monotonicMs);
  int get totalMs =>
      (_state['totalBaseMs'] as int? ?? 0) +
      (running && !needsReview
          ? _delta(clock.monotonicMs, _state['runMonoMs'] as int)
          : 0);
  int get actionMs => running && !needsReview
      ? _delta(clock.monotonicMs, (_state['active'] as Map)['monoMs'] as int)
      : 0;
  int _delta(int end, int start) {
    if (end < start) throw StateError('Elapsed clock moved backwards.');
    return end - start;
  }

  Future<void> initialize() async {
    await location.initialize();
    events.addAll(await journal.recent());
    if (events.isNotEmpty) {
      _state = Map<String, dynamic>.from(events.last['state'] as Map);
      recovered = running;
    }
    await _restoreActivityTotals();
    await _restoreRecentIntervals();
    _audioSubscription = audio.events.listen(
      _audioChanged,
      onError: (Object _) {},
    );
    location.addListener(_sensorChanged);
    _motionSubscription = motion.readings.listen((reading) {
      _motion = reading;
      _sensorChanged();
    });
    _motion = await motion.read();
    if (running && !needsReview) {
      // A process restart never rewrites a boundary using wall-clock duration.
      // The same boot's continuous clock resumes directly from the CSV anchor.
      _delta(clock.monotonicMs, _state['runMonoMs'] as int);
      await _enqueue('recovered', _boundary());
      _startSensors();
      if (_visible && !kIsWeb) unawaited(_prepareLocation());
    } else if (!running && _visible && !kIsWeb) {
      unawaited(_prepareLocation());
    }
    notifyListeners();
  }

  void _sensorChanged() {
    if (!_closed && _visible) {
      sensorTicks.value++;
      ticks.value++;
    }
  }

  void setVisible(bool visible) {
    if (_visible == visible) return;
    _visible = visible;
    if (visible &&
        running &&
        !kIsWeb &&
        [
          'permission_required',
          'denied',
          'disabled',
          'off',
          'error',
          'unavailable',
        ].contains(gps['status'])) {
      unawaited(_prepareLocation());
    }
    if (!running) {
      if (visible && !kIsWeb) {
        unawaited(_prepareLocation());
      } else {
        _cancelGpsWarmup();
        _sensors.endWarmUp();
      }
    }
    if (!_closed) notifyListeners();
  }

  Map<String, dynamic> _boundary() {
    final mono = clock.monotonicMs;
    final reading = _motion.sessionId == 'actions-$studyId' ? _motion : null;
    return {
      'utc': clock.wallTime.toUtc().toIso8601String(),
      'monoMs': mono,
      'location': location.at(mono),
      'motion': reading?.toMap(),
    };
  }

  Future<void> select(String selected) {
    if (!fieldActions.contains(selected)) throw ArgumentError.value(selected);
    if (selected == 'Delay') return toggleDelay();
    return _enqueue('action', _boundary(), selected: selected);
  }

  /// One field gesture starts a stopped recorder or switches a running one.
  /// Resolve it in the serialized queue, while preserving the gesture boundary.
  Future<void> capture(String selected) {
    if (!fieldActions.take(4).contains(selected)) {
      throw ArgumentError.value(selected);
    }
    return _enqueue('capture', _boundary(), selected: selected);
  }

  Future<void> stop() => _enqueue('stop', _boundary());

  Future<void> toggleDelay() => setDelay(!delayRunning);
  Future<void> setDelay(bool active) =>
      _enqueue(active ? 'delay_start' : 'delay_end', _boundary());
  Future<void> chooseDelayReason(String reason) {
    if (!delayReasons.contains(reason)) throw ArgumentError.value(reason);
    return _enqueue('delay_reason', _boundary(), reason: reason);
  }

  Future<void> startStop() => _enqueue(running ? 'stop' : 'start', _boundary());
  Future<void> newStudy({String title = 'Field study'}) {
    final name = _validTitle(title);
    if (_audioBusy == 0 && _state['audioCleanupStudyId'] == null) {
      return _enqueue('new_study', _boundary(), title: name);
    }
    return _prepareNewStudy(name);
  }

  Future<void> _prepareNewStudy(String name) async {
    if (running || pending != 0) return;
    await _audioWork;
    await _tail;
    if (!running && pending == 0 && _state['audioCleanupStudyId'] is String) {
      await audio.deleteStudy(_state['audioCleanupStudyId'] as String);
      await _enqueue('audio_cleanup', _boundary());
    }
    await _enqueue('new_study', _boundary(), title: name);
  }

  Future<void> renameStudy(String title) =>
      _enqueue('rename_study', _boundary(), title: _validTitle(title));
  String _validTitle(String value) {
    final title = value.trim().replaceAll(RegExp(r'[\r\n\x00-\x1f]'), ' ');
    if (title.isEmpty || title.length > 80) {
      throw ArgumentError('Use a study name of 1 to 80 characters.');
    }
    return title;
  }

  Future<void> resetStudy() async {
    if (running || pending != 0 || error != null || needsReview) {
      throw StateError('Stop before Reset.');
    }
    await _audioWork;
    await _tail;
    if (running || pending != 0 || error != null) {
      throw StateError('Study changed before Reset.');
    }
    final store = journal;
    if (store is! ResettableActionJournal) {
      throw StateError('This storage does not support Reset.');
    }
    final id = studyId;
    final cleanup = _state['audioCleanupStudyId'] as String?;
    if (cleanup != null) {
      await audio.deleteStudy(cleanup);
      await _enqueue('audio_cleanup', _boundary());
      if (count == 0) return;
    }
    final replacement = _makeEvent(
      'new_study',
      _boundary(),
      null,
      null,
      title,
    )!;
    replacement['kind'] = 'reset';
    (replacement['state'] as Map)['audioCleanupStudyId'] = id;
    pending++;
    notifyListeners();
    try {
      await store.resetStudy(id, replacement);
      events
        ..clear()
        ..addAll(await store.recent());
      _state = Map<String, dynamic>.from(events.last['state'] as Map);
      recovered = false;
      ticks.value++;
      // Data commit precedes file deletion. Failed deletion is surfaced and can
      // be retried; never risk deleting another project's audio.
      await audio.deleteStudy(id);
    } finally {
      pending--;
      if (!_closed) notifyListeners();
    }
    await _enqueue('audio_cleanup', _boundary());
  }

  Future<void> closeInterrupted() => _enqueue('interrupted', _boundary());

  Future<void> _enqueue(
    String kind,
    Map<String, dynamic> boundary, {
    String? selected,
    String? reason,
    String? title,
    Map<String, dynamic>? audioNote,
  }) {
    if (_closed || error != null) return Future.value();
    final generation = _generation;
    pending++;
    notifyListeners();
    final operation = _tail.then((_) async {
      try {
        if (_closed || generation != _generation) return;
        final event = _makeEvent(kind, boundary, selected, reason, title);
        if (event == null) return;
        if (audioNote != null) {
          event['audioNote'] = Map<String, dynamic>.from(audioNote);
        }
        _retry = event;
        await journal.append(event);
        _accept(event);
      } catch (failure) {
        error = failure;
        _generation++;
      } finally {
        pending--;
        if (!_closed) notifyListeners();
      }
    });
    _tail = operation;
    return operation;
  }

  Map<String, dynamic>? _makeEvent(
    String kind,
    Map<String, dynamic> boundary,
    String? selected,
    String? reason,
    String? newTitle,
  ) {
    if (needsReview && kind != 'interrupted') return null;
    if (kind == 'capture') {
      if (!canCapture(selected!)) return null;
      kind = running ? 'action' : 'start';
    }
    if (kind == 'new_study' && running ||
        kind == 'stop' && !running ||
        kind == 'start' && running) {
      return null;
    }
    if (kind == 'interrupted' && !needsReview) return null;
    if (kind == 'start' && action == 'Delay') return null;
    if (kind == 'delay_start' &&
        (!running || delayRunning || action == 'Delay')) {
      return null;
    }
    if ((kind == 'delay_end' || kind == 'delay_reason') &&
        (!running || !delayRunning)) {
      return null;
    }
    boundary = Map<String, dynamic>.from(boundary);
    final state = Map<String, dynamic>.from(_state);
    final mono = boundary['monoMs'] as int;
    final total = needsReview
        ? _state['totalBaseMs'] as int? ?? 0
        : (_state['totalBaseMs'] as int? ?? 0) +
              (running ? _delta(mono, _state['runMonoMs'] as int) : 0);
    Map<String, dynamic>? closed;
    Map<String, dynamic>? delayClosed;
    final lastDurations = <String, dynamic>{
      for (final name in fieldActions) name: _lastDuration(name),
    };
    final lastDelayCounts = <String, int>{
      for (final name in fieldActions.take(4)) name: displayDelayCount(name),
    };
    final activityTotals = <String, int?>{
      for (final name in fieldActions.take(4)) name: completedActivityMs(name),
    };
    var logNumber = count + delayCount;
    final switching = kind == 'action' && running && selected != action;
    if (delayRunning &&
        (kind == 'delay_end' ||
            switching ||
            kind == 'stop' ||
            kind == 'interrupted')) {
      final delay = _state['delay'] as Map;
      delayClosed = {
        'action': 'Delay',
        'parentActivity': delay['parentActivity'],
        'reason': delay['reason'],
        'reasonAt': delay['reasonAt'],
        'cycle': delay['cycle'],
        'ordinal': delay['ordinal'],
        'start': delay['start'],
        'end': kind == 'interrupted' ? null : boundary,
        'durationMs': kind == 'interrupted'
            ? null
            : _delta(mono, (delay['start'] as Map)['monoMs'] as int),
        'number': ++logNumber,
        'overlap': true,
        'audioFile': delay['audioFile'],
        if (kind == 'interrupted') 'reviewedAt': boundary,
      };
      lastDurations['Delay'] = delayClosed['durationMs'];
      state['lastDelayReason'] = delay['reason'];
      state['delayCount'] = delayCount + 1;
      state['delay'] = null;
    }
    if (switching || kind == 'stop' || kind == 'interrupted') {
      final start = _state['active'] as Map;
      closed = {
        'action': action,
        'cycle': activityCycle,
        'delayCount': activityDelayCount,
        'start': start,
        'end': kind == 'interrupted' ? null : boundary,
        if (kind == 'interrupted') 'reviewedAt': boundary,
        'durationMs': kind == 'interrupted'
            ? null
            : _delta(mono, start['monoMs'] as int),
        if (kind == 'interrupted') 'interrupted': true,
        'number': ++logNumber,
      };
      state['count'] = count + 1;
      lastDurations[action] = closed['durationMs'];
      lastDelayCounts[action] = activityDelayCount;
      if (activityTotals.containsKey(action)) {
        final previous = activityTotals[action];
        final duration = closed['durationMs'] as int?;
        activityTotals[action] = previous == null || duration == null
            ? null
            : previous + duration;
      }
    }
    if (kind == 'new_study' || state.isEmpty) {
      state.clear();
      state.addAll({
        'studyId':
            'study-${boundary['utc'].toString().replaceAll(RegExp(r'[^0-9]'), '')}-${sequence + 1}',
        'title': newTitle ?? title,
        'totalBaseMs': 0,
        'count': 0,
        'running': false,
        'action': 'Walking',
        'delayCount': 0,
        'cycle': 0,
        'cycleHasWalking': false,
        'activeDelayCount': 0,
        'activityTotalsMs': {for (final name in fieldActions.take(4)) name: 0},
      });
    } else {
      state['lastDurations'] = lastDurations;
      state['lastDelayCounts'] = lastDelayCounts;
      state['activityTotalsMs'] = activityTotals;
      // Keep only compact lap summaries in state, so repeat taps and process
      // recovery cannot push the latest completed lap out of the event window.
      state['recentIntervals'] =
          [
                if (closed != null) {...closed, 'overlap': false},
                if (delayClosed != null) {...delayClosed, 'overlap': true},
                ...recentIntervals,
              ]
              .take(12)
              .map(
                (interval) => <String, dynamic>{
                  for (final key in [
                    'number',
                    'action',
                    'durationMs',
                    'overlap',
                    'reason',
                    'cycle',
                    'delayCount',
                    'ordinal',
                  ])
                    key: interval[key],
                },
              )
              .toList();
    }
    if (selected != null) state['action'] = selected;
    if (kind == 'start' || switching) {
      final next = selected ?? action;
      var nextCycle = state['cycle'] as int? ?? 0;
      if (next == 'Planting') {
        nextCycle++;
      }
      state['cycle'] = nextCycle;
      state['activeDelayCount'] = 0;
    }
    final motionAtGesture = boundary['motion'] as Map?;
    if (motionAtGesture?['sessionId'] != 'actions-${state['studyId']}') {
      // New study can be queued before its save finishes. Its gestures must
      // not inherit the previous study's cumulative walking measurement.
      boundary['motion'] = null;
    }
    if (running && kind != 'new_study') {
      // Every acknowledged boundary preserves the known elapsed prefix, so a
      // later device reboot cannot erase previously timed activities.
      state['totalBaseMs'] = total;
      state['runMonoMs'] = mono;
    }
    if (kind == 'start') {
      state.addAll({
        'running': true,
        'action': selected ?? action,
        'active': boundary,
        'runMonoMs': mono,
        'bootId': location.bootId,
        'delay': null,
      });
    } else if (kind == 'delay_start') {
      state['activeDelayCount'] = activityDelayCount + 1;
      state['delay'] = {
        'start': boundary,
        'parentActivity': action,
        'reason': null,
        'cycle': activityCycle,
        'ordinal': activityDelayCount + 1,
        'audioFile': 'note-${state['studyId']}-$mono.m4a',
      };
    } else if (kind == 'delay_reason') {
      state['delay'] = {
        ...(_state['delay'] as Map),
        'reason': reason,
        'reasonAt': boundary,
      };
    } else if (switching) {
      state['active'] = boundary;
    } else if (kind == 'stop' || kind == 'interrupted') {
      state.addAll({
        'running': false,
        'totalBaseMs': total,
        'active': null,
        if (kind == 'interrupted')
          'unknownIntervals': (_state['unknownIntervals'] as int? ?? 0) + 1,
      });
    }
    if (kind == 'rename_study') state['title'] = newTitle;
    if (kind == 'audio_cleanup') state.remove('audioCleanupStudyId');
    state['seq'] = sequence + 1;
    // Freeze nested data before asynchronous storage. Retries retain the exact
    // gesture time and sensor fix, even when a permission dialog takes seconds.
    return Map<String, dynamic>.from(
      jsonDecode(
            jsonEncode({
              'seq': sequence + 1,
              'kind': kind == 'action' && running && !switching
                  ? 'repeat'
                  : kind,
              'boundary': boundary,
              'closed': closed,
              if (delayClosed != null) 'delayClosed': delayClosed,
              'state': state,
              'totalMs': kind == 'new_study' ? 0 : total,
            }),
          )
          as Map,
    );
  }

  void _accept(Map<String, dynamic> event) {
    final wasRunning = running;
    _state = Map<String, dynamic>.from(event['state'] as Map);
    events.add(event);
    if (events.length > 20) events.removeAt(0);
    _retry = null;
    if (event['kind'] == 'new_study' || event['kind'] == 'stop') {
      recovered = false;
    }
    error = null;
    ticks.value++;
    if (!wasRunning && running) _startSensors();
    if (wasRunning && !running) _stopSensors();
    final wanted = (_state['delay'] as Map?)?['audioFile'] as String?;
    if (wanted != _audioTarget) {
      _audioTarget = wanted;
      audioStatus = wanted == null ? 'off' : 'requesting';
      _audioBusy++;
      final work = _changeAudio(wanted).whenComplete(() => _audioBusy--);
      _audioWork = Future.wait([_audioWork, work]).then((_) {});
    }
    if (event['kind'] == 'new_study' && _visible && !kIsWeb) {
      unawaited(_prepareLocation());
    }
  }

  Future<void> _changeAudio(String? file) async {
    final result = await audio.setTarget(file);
    if (_closed || result == null) return;
    if (file == _audioTarget) {
      audioStatus = file == null
          ? 'off'
          : result['status'] as String? ?? 'error';
      notifyListeners();
    }
    if (result['file'] != null) {
      await _enqueue('audio_note', _boundary(), audioNote: result);
    }
  }

  void _audioChanged(Map<String, dynamic> result) {
    if (_closed) return;
    if (result['file'] == _audioTarget) {
      audioStatus = result['status'] as String? ?? 'error';
      notifyListeners();
    }
    unawaited(_enqueue('audio_note', _boundary(), audioNote: result));
  }

  Future<void> retrySave() async {
    final event = _retry;
    if (event == null || pending != 0) return;
    pending++;
    notifyListeners();
    try {
      await journal.append(event);
      _accept(event);
    } catch (failure) {
      error = failure;
    } finally {
      pending--;
      if (!_closed) notifyListeners();
    }
  }

  void _startSensors() {
    _cancelGpsWarmup();
    _sensors.setRunning('actions-$studyId', stepLengthM: _motion.stepLengthM);
  }

  void _stopSensors() {
    _cancelGpsWarmup();
    _sensors.setRunning(null);
  }

  Future<MotionReading> setStepLength(double value) async {
    if (running) throw StateError('Stop timing before changing step length.');
    await _sensors.settled;
    _motion = await motion.setStepLength(stepLengthM: value);
    _sensorChanged();
    return _motion;
  }

  void _cancelGpsWarmup() {
    _gpsWarmupRevision++;
    _gpsWarmup?.cancel();
    _gpsWarmup = null;
  }

  Future<void> _prepareLocation() async {
    if (_closed || !_visible && !running) return;
    _cancelGpsWarmup();
    final revision = _gpsWarmupRevision;
    // GPS is automatic. Ask through the OS once per recorder opening; later
    // foreground returns reuse permission without repeatedly prompting denial.
    // Capture boundaries and durable writes never wait for this permission.
    final requestPermission = _visible && !_gpsPermissionRequested;
    if (requestPermission) _gpsPermissionRequested = true;
    await _sensors.warmUp(requestPermission: requestPermission);
    if (_closed || revision != _gpsWarmupRevision) return;
    if (!running && _visible) {
      _gpsWarmup = Timer(const Duration(minutes: 1), () {
        if (!running && !_closed && revision == _gpsWarmupRevision) {
          _sensors.endWarmUp();
        }
      });
    } else if (!running) {
      _sensors.endWarmUp();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    if (_audioTarget != null) {
      _audioTarget = null;
      await _changeAudio(null);
    }
    await _tail;
    _closed = true;
    _cancelGpsWarmup();
    await _sensors.close(stop: !running);
    location.removeListener(_sensorChanged);
    location.dispose();
    await _motionSubscription?.cancel();
    await _audioSubscription?.cancel();
    await motion.dispose();
    await journal.close();
    ticks.dispose();
    sensorTicks.dispose();
    super.dispose();
  }
}
