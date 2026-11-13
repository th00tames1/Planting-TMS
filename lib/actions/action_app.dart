import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import '../export/export_file_saver.dart';
import 'action_recorder.dart';
import 'open_action_journal.dart';
import 'capture_time.dart';
import 'saved_records_screen.dart';
import 'app_updates.dart';
import 'appearance.dart';
import 'capture_permissions.dart';

const _paper = Color(0xFFF5F7F9);
const _ink = Color(0xFF19232E);
const _blue = Color(0xFF2458D8);
const _figures = [FontFeature.tabularFigures()];
Color _fieldInk(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface;
Color _fieldMuted(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;
Color _fieldButton(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF1B222C)
    : const Color(0xFFFCFDFE);
Color _fieldOutline(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF526172)
    : const Color(0xFFCED7E1);
Color _fieldAccent(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF9BB8FF)
    : _blue;
Color _fieldError(BuildContext context) => Theme.of(context).colorScheme.error;
Color _fieldDisabledInk(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF4F5967)
    : const Color(0xFFADB5BF);
Color _fieldDisabledButton(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF141920)
    : const Color(0xFFEDF0F3);
Color _fieldDisabledOutline(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF29313D)
    : const Color(0xFFDFE4EA);

class ActionCaptureApp extends StatelessWidget {
  const ActionCaptureApp({super.key, this.recorder});
  final ActionRecorder? recorder;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
    valueListenable: Appearance.mode,
    child: _CaptureHost(recorder: recorder),
    builder: (context, mode, child) => MaterialApp(
      title: 'Planting TMS',
      debugShowCheckedModeBanner: false,
      themeMode: mode,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF10141B),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF9BB8FF),
          brightness: Brightness.dark,
          surface: const Color(0xFF10141B),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF10141B),
          foregroundColor: Color(0xFFEAF0F7),
          surfaceTintColor: Colors.transparent,
        ),
      ),
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: _paper,
        colorScheme: ColorScheme.fromSeed(seedColor: _blue, surface: _paper),
        appBarTheme: const AppBarTheme(
          backgroundColor: _paper,
          foregroundColor: _ink,
          surfaceTintColor: Colors.transparent,
        ),
        textTheme: const TextTheme(bodyMedium: TextStyle(color: _ink)),
      ),
      home: child,
    ),
  );
}

class _CaptureHost extends StatefulWidget {
  const _CaptureHost({this.recorder});
  final ActionRecorder? recorder;
  @override
  State<_CaptureHost> createState() => _CaptureHostState();
}

class _CaptureHostState extends State<_CaptureHost>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final Ticker _displayTicker;
  (int, int, int)? _lastDisplayStep;
  int? _lastRenderedFrameUs;
  ActionRecorder? c;
  Object? openingError;
  bool exporting = false;
  bool _stopping = false;
  bool _editing = false;
  String? _pressedActivity;
  int? _pressedActionStartMs;
  int? _pressedActivityDelayCount;
  int? _pressedCycle;
  int? _pressedClosedRecords;
  int _recordRevision = 0;
  _CaptureLap? _pressedPreviousLap;
  Map<String, int?>? _pressedTotalsAtStart;
  int _countRevision = 0;
  int _selectionRevision = 0;
  bool? _pressedDelay;
  int? _pressedDelayStartMs;
  String? _pressedReason;
  int _delayRevision = 0;
  int _reasonRevision = 0;
  bool _covered = false;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;
  @override
  void initState() {
    super.initState();
    unawaited(Appearance.load());
    _displayTicker = createTicker(_displayFrame);
    _lifecycle =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_open());
  }

  Future<void> _open() async {
    ActionRecorder? recorder;
    try {
      if (widget.recorder == null) await prepareCapturePermissions();
      recorder = widget.recorder ?? ActionRecorder(await openActionJournal());
      recorder.setVisible(!_covered && _lifecycle == AppLifecycleState.resumed);
      await recorder.initialize();
      if (!mounted) {
        await recorder.close();
        return;
      }
      recorder.addListener(_changed);
      recorder.setVisible(!_covered && _lifecycle == AppLifecycleState.resumed);
      setState(() => c = recorder);
      _syncDisplayTicker();
      if (!recorder.running) unawaited(AppUpdates().autoCheck());
    } catch (failure) {
      await recorder?.close();
      if (mounted) setState(() => openingError = failure);
    }
  }

  void _changed() {
    if (mounted) {
      _lastDisplayStep = null;
      _lastRenderedFrameUs = null;
      _syncDisplayTicker();
      setState(() {});
    }
  }

  void _syncDisplayTicker() {
    if (c?.shouldRefreshDisplay == true) {
      if (!_displayTicker.isActive) {
        _lastDisplayStep = null;
        _lastRenderedFrameUs = null;
        _displayTicker.start();
      }
    } else {
      _displayTicker.stop();
    }
  }

  void _displayFrame(Duration elapsed) {
    final recorder = c;
    if (recorder == null || !recorder.shouldRefreshDisplay) return;
    // A stopwatch readout needs at most 60 updates/s, even on 120 Hz phones.
    // Keep measurement timestamps independent of this rendering budget.
    final frameUs = elapsed.inMicroseconds;
    if (_lastRenderedFrameUs != null &&
        frameUs - _lastRenderedFrameUs! < 16000) {
      return;
    }
    final now = recorder.clock.monotonicMs;
    final activeMs = _pressedActionStartMs == null
        ? recorder.actionMs
        : now - _pressedActionStartMs!;
    final delayMs = (_pressedDelay ?? recorder.delayRunning)
        ? _pressedDelayStartMs == null
              ? recorder.delayMs ?? 0
              : now - _pressedDelayStartMs!
        : 0;
    final step = (recorder.totalMs ~/ 10, activeMs ~/ 10, delayMs ~/ 10);
    if (_lastDisplayStep == step) return;
    _lastDisplayStep = step;
    _lastRenderedFrameUs = frameUs;
    recorder.refreshDisplay();
  }

  void _select(String name) {
    final recorder = c!;
    if (name == 'Delay') {
      final requested = !(_pressedDelay ?? recorder.delayRunning);
      final recordRevision = ++_recordRevision;
      final closedRecords =
          (_pressedClosedRecords ?? recorder.count + recorder.delayCount) +
          (requested ? 0 : 1);
      final revision = ++_delayRevision;
      final countRevision = requested ? ++_countRevision : _countRevision;
      final delayCount =
          (_pressedActivityDelayCount ?? recorder.activityDelayCount) + 1;
      _reasonRevision++;
      final save = recorder.setDelay(requested);
      setState(() {
        _pressedDelay = requested;
        _pressedDelayStartMs = requested ? recorder.clock.monotonicMs : null;
        _pressedReason = null;
        _pressedClosedRecords = closedRecords;
        if (requested) _pressedActivityDelayCount = delayCount;
      });
      unawaited(
        save.whenComplete(() {
          if (mounted && recordRevision == _recordRevision) {
            setState(() => _pressedClosedRecords = null);
          }
          if (mounted && revision == _delayRevision) {
            setState(() {
              _pressedDelay = null;
              _pressedDelayStartMs = null;
            });
          }
          if (mounted && requested && countRevision == _countRevision) {
            setState(() => _pressedActivityDelayCount = null);
          }
        }),
      );
      return;
    }
    final switching = name != (_pressedActivity ?? recorder.action);
    final starting = !recorder.running && _pressedActivity == null;
    final previousAction =
        _pressedActivity ?? (recorder.running ? recorder.action : null);
    final previousIsDelay = _pressedDelay ?? recorder.delayRunning;
    final closedBefore =
        _pressedClosedRecords ?? recorder.count + recorder.delayCount;
    final previousMs = previousIsDelay
        ? _pressedDelayStartMs == null
              ? recorder.delayMs
              : recorder.clock.monotonicMs - _pressedDelayStartMs!
        : _pressedActionStartMs == null
        ? recorder.actionMs
        : recorder.clock.monotonicMs - _pressedActionStartMs!;
    final previousLap = switching && previousAction != null
        ? _CaptureLap(
            id: 'outgoing',
            number: closedBefore + 1,
            action: previousIsDelay ? 'Delay' : previousAction,
            reason: previousIsDelay
                ? _pressedReason ?? recorder.delayReason
                : null,
            cycle: previousAction == 'Planting' || previousAction == 'Walking'
                ? _pressedCycle ?? recorder.cycle
                : null,
            elapsed: () => previousMs,
          )
        : _pressedPreviousLap;
    final cycle =
        (_pressedCycle ?? recorder.cycle) +
        ((switching || starting) && name == 'Planting' ? 1 : 0);
    final countRevision = ++_countRevision;
    final counter = switching || starting ? 0 : _pressedActivityDelayCount;
    final startMs = switching || starting
        ? recorder.clock.monotonicMs
        : _pressedActionStartMs;
    final totalsAtStart = switching || starting
        ? {
            for (final activity in fieldActions.take(4))
              activity: _previewTotal(activity),
          }
        : _pressedTotalsAtStart;
    final delayRevision = switching ? ++_delayRevision : _delayRevision;
    if (switching) {
      _reasonRevision++;
      _pressedReason = null;
    }
    final revision = ++_selectionRevision;
    final recordRevision = ++_recordRevision;
    final closedRecords =
        closedBefore +
        (switching && previousAction != null ? (previousIsDelay ? 2 : 1) : 0);
    final save = recorder.capture(name);
    setState(() {
      _pressedActivity = name;
      _pressedActionStartMs = startMs;
      _pressedActivityDelayCount = counter;
      _pressedCycle = cycle;
      _pressedClosedRecords = closedRecords;
      _pressedPreviousLap = previousLap;
      _pressedTotalsAtStart = totalsAtStart;
      if (switching) _pressedDelay = false;
    });
    unawaited(
      save.whenComplete(() {
        if (mounted && recordRevision == _recordRevision) {
          setState(() => _pressedClosedRecords = null);
        }
        if (mounted && revision == _selectionRevision) {
          setState(() {
            _pressedActivity = null;
            _pressedActionStartMs = null;
            _pressedTotalsAtStart = null;
            _pressedCycle = null;
            _pressedPreviousLap = null;
          });
        }
        if (mounted && switching && delayRevision == _delayRevision) {
          setState(() {
            _pressedDelay = null;
            _pressedDelayStartMs = null;
          });
        }
        if (mounted && countRevision == _countRevision) {
          setState(() => _pressedActivityDelayCount = null);
        }
      }),
    );
  }

  int? _previewTotal(String name) {
    final snapshot = _pressedTotalsAtStart;
    if (snapshot == null) return c!.cumulativeActivityMs(name);
    final total = snapshot[name];
    if (total == null) return null;
    return total +
        (_pressedActivity == name && _pressedActionStartMs != null
            ? c!.clock.monotonicMs - _pressedActionStartMs!
            : 0);
  }

  void _chooseReason(String reason) {
    final revision = ++_reasonRevision;
    final save = c!.chooseDelayReason(reason);
    setState(() => _pressedReason = reason);
    unawaited(
      save.whenComplete(() {
        if (mounted && revision == _reasonRevision) {
          setState(() => _pressedReason = null);
        }
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    c?.setVisible(!_covered && state == AppLifecycleState.resumed);
  }

  Future<void> _visit(WidgetBuilder builder) async {
    _covered = true;
    c!.setVisible(false);
    try {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: builder));
    } finally {
      _covered = false;
      if (mounted) c?.setVisible(_lifecycle == AppLifecycleState.resumed);
    }
  }

  @override
  void dispose() {
    _displayTicker.dispose();
    WidgetsBinding.instance.removeObserver(this);
    c?.removeListener(_changed);
    if (c != null) unawaited(c!.close());
    super.dispose();
  }

  Future<void> _export() async {
    final recorder = c!;
    if (exporting || recorder.running || recorder.pending != 0) return;
    setState(() => exporting = true);
    try {
      final saver = createExportFileSaver();
      final name =
          'field-study-${DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[^0-9]'), '')}.csv';
      ExportSaveResult result;
      if (saver is StreamingExportFileSaver) {
        result = await saver.saveStream(
          fileName: name,
          mimeType: 'text/csv',
          write: (sink) async {
            var bytes = 0;
            await for (final chunk in recorder.journal.csv()) {
              await sink(chunk);
              bytes += chunk.length;
            }
            return ExportSummary(
              recordCount: recorder.sequence,
              byteCount: bytes,
            );
          },
        );
      } else {
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in recorder.journal.csv()) {
          if (bytes.length + chunk.length > 32 * 1024 * 1024) {
            throw const ExportException(
              'Preview export is limited to 32 MB. Use the mobile app for larger studies.',
            );
          }
          bytes.add(chunk);
        }
        result = await saver.save(
          ExportDocument(
            bytes: bytes.takeBytes(),
            fileName: name,
            mimeType: 'text/csv',
            recordCount: recorder.sequence,
          ),
        );
      }
      if (mounted) {
        _showNotice(switch (result.status) {
          ExportSaveStatus.saved => 'CSV copy saved.',
          ExportSaveStatus.downloadStarted => 'CSV download started.',
          ExportSaveStatus.cancelled => 'CSV copy cancelled.',
          ExportSaveStatus.failed =>
            result.message ?? 'Could not save CSV copy.',
        });
      }
    } catch (_) {
      if (mounted) {
        _showNotice(
          'Could not save CSV copy. The original recording is retained.',
        );
      }
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  void _showNotice(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _menu(String choice) async {
    if (!mounted) return;
    final recorder = c!;
    if (choice == 'stop') {
      if ((recorder.running || _pressedActivity != null) &&
          !_stopping &&
          recorder.error == null &&
          !recorder.needsReview &&
          !exporting) {
        setState(() => _stopping = true);
        try {
          await recorder.stop();
          if (!recorder.running) unawaited(AppUpdates().autoCheck());
        } finally {
          if (mounted) setState(() => _stopping = false);
        }
      }
      return;
    }
    if (choice == 'csv') {
      await _export();
      return;
    }
    if (choice == 'new') {
      await _editTitle(newStudy: true);
      return;
    }
    if (choice == 'reset') {
      if (recorder.running || recorder.pending != 0 || !recorder.canReset) {
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Reset this study?'),
          content: const Text(
            'Delete all records and audio notes for this study and reset every timer and Cycle to zero? The study name will stay. This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                'Delete and reset',
                style: TextStyle(color: _fieldError(context)),
              ),
            ),
          ],
        ),
      );
      if (confirmed == true && mounted) {
        setState(() => _editing = true);
        try {
          await recorder.resetStudy();
        } catch (_) {
          if (mounted) {
            _showNotice(
              'Reset could not finish. Choose Reset again to retry. Previously exported copies are unchanged.',
            );
          }
        } finally {
          if (mounted) setState(() => _editing = false);
        }
      }
      return;
    }
    if (choice == 'settings') {
      if (exporting || recorder.pending != 0 || _stopping) return;
      await _visit((_) => AppSettings(recorder: recorder));
      return;
    }
    if (choice == 'records') {
      if (exporting || recorder.pending != 0 || _stopping) return;
      await _visit(
        (_) => SavedRecordsScreen(
          journal: recorder.journal,
          maxSequence: recorder.sequence,
          audio: recorder.audio,
        ),
      );
    }
  }

  Future<void> _editTitle({bool newStudy = false}) async {
    if (_editing || exporting || c!.pending != 0 || newStudy && c!.running) {
      return;
    }
    final input = TextEditingController(text: newStudy ? '' : c!.title);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(newStudy ? 'New study' : 'Study name'),
        content: TextField(
          controller: input,
          autofocus: true,
          maxLength: 80,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Project name'),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (input.text.trim().isNotEmpty) {
                Navigator.pop(context, input.text.trim());
              }
            },
            child: Text(newStudy ? 'Create study' : 'Save name'),
          ),
        ],
      ),
    );
    // Let the closing route finish releasing its text field before disposal.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    input.dispose();
    if (name == null || !mounted) return;
    try {
      if (newStudy) {
        await c!.newStudy(title: name);
      } else {
        await c!.renameStudy(name);
      }
    } catch (_) {
      if (mounted) {
        _showNotice(
          'Could not update the study. Existing records are retained.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final recorder = c;
    if (recorder == null) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: openingError == null
                  ? const Text('Opening saved study…')
                  : const Text(
                      'Could not open the recording. Your original files have been preserved. Close and reopen the app to retry.',
                    ),
            ),
          ),
        ),
      );
    }
    final enabled =
        recorder.error == null &&
        !recorder.needsReview &&
        !exporting &&
        !_editing &&
        !_stopping;
    final running = recorder.running || _pressedActivity != null;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 48,
        title: InkWell(
          onTap: enabled && recorder.pending == 0 ? _editTitle : null,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    recorder.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.edit_outlined,
                  size: 16,
                  color: _fieldMuted(context),
                ),
              ],
            ),
          ),
        ),
        actions: [
          if (recorder.delayRunning)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: _AudioStatus(recorder: recorder),
            ),
          PopupMenuButton<String>(
            tooltip: 'Study options',
            onSelected: _menu,
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'reset',
                enabled:
                    enabled &&
                    !running &&
                    recorder.pending == 0 &&
                    recorder.canReset,
                child: const Text('Reset'),
              ),
              if (running)
                PopupMenuItem(
                  key: const ValueKey('capture-stop'),
                  value: 'stop',
                  enabled: enabled,
                  child: Text(
                    'Stop',
                    style: TextStyle(color: _fieldError(context)),
                  ),
                ),
              PopupMenuItem(
                value: 'records',
                enabled: !exporting && recorder.pending == 0 && !_stopping,
                child: const Text('Saved records'),
              ),
              PopupMenuItem(
                value: 'csv',
                enabled:
                    !recorder.running &&
                    recorder.pending == 0 &&
                    !exporting &&
                    recorder.error == null,
                child: const Text('Extract CSV'),
              ),
              PopupMenuItem(
                value: 'settings',
                enabled: !exporting && recorder.pending == 0 && !_editing,
                child: const Text('Settings'),
              ),
              PopupMenuItem(
                value: 'new',
                enabled:
                    !recorder.running &&
                    recorder.pending == 0 &&
                    !exporting &&
                    recorder.error == null,
                child: const Text('New study'),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _CapturePanel(
          recorder: recorder,
          enabled: enabled,
          running: running,
          cycle: _pressedCycle ?? recorder.cycle,
          closedRecords:
              _pressedClosedRecords ?? recorder.count + recorder.delayCount,
          previousLap: _pressedPreviousLap,
          selected: running ? _pressedActivity ?? recorder.action : null,
          actionStartMs: _pressedActionStartMs,
          activityDelayCount: _pressedActivityDelayCount,
          totalsAtStart: _pressedTotalsAtStart,
          delayStartMs: _pressedDelayStartMs,
          delayActive: _pressedDelay ?? recorder.delayRunning,
          delayReason: _pressedDelayStartMs != null
              ? _pressedReason
              : _pressedReason ?? recorder.delayReason,
          onReason: _chooseReason,
          onSelect: _select,
        ),
      ),
    );
  }
}

class _CapturePanel extends StatelessWidget {
  const _CapturePanel({
    required this.recorder,
    required this.enabled,
    required this.running,
    required this.cycle,
    required this.closedRecords,
    required this.selected,
    required this.onSelect,
    required this.delayActive,
    required this.onReason,
    this.actionStartMs,
    this.previousLap,
    this.activityDelayCount,
    this.totalsAtStart,
    this.delayStartMs,
    this.delayReason,
  });
  final ActionRecorder recorder;
  final bool enabled, running;
  final int cycle, closedRecords;
  final _CaptureLap? previousLap;
  final String? selected, delayReason;
  final int? actionStartMs, delayStartMs;
  final int? activityDelayCount;
  final Map<String, int?>? totalsAtStart;
  final ValueChanged<String> onSelect, onReason;
  final bool delayActive;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, viewport) {
      final compact = viewport.maxHeight < 600;
      final gap = compact ? 16.0 : 20.0;
      final screenHeight = MediaQuery.sizeOf(context).height;
      final halfHeight =
          screenHeight / 2 -
          MediaQueryData.fromView(View.of(context)).padding.bottom -
          (compact ? 8 : 12);
      final rows =
          viewport.maxHeight < 320 &&
              MediaQuery.orientationOf(context) == Orientation.landscape
          ? 2
          : 3;
      final preferredHeight = rows * 124.0 + (rows - 1) * gap;
      final bottomHeight = math
          .max(
            halfHeight,
            math.min(preferredHeight, halfHeight + screenHeight * .08),
          )
          .clamp(0.0, viewport.maxHeight * .75);
      final alert = recorder.needsReview
          ? _CaptureAlert(
              text: 'Interrupted.\nDuration is unknown.',
              label: 'Close activity',
              onTap: recorder.closeInterrupted,
            )
          : recorder.error != null
          ? _CaptureAlert(
              text: 'Not saved.\nRetry to keep recording.',
              label: 'Retry save',
              onTap: recorder.retrySave,
            )
          : null;
      final grid = _ActivityGrid(
        recorder: recorder,
        selected: selected,
        enabled: enabled,
        running: running,
        actionStartMs: actionStartMs,
        activityDelayCount: activityDelayCount,
        totalsAtStart: totalsAtStart,
        delayStartMs: delayStartMs,
        onSelect: onSelect,
        delayActive: delayActive,
        delayReason: delayReason,
        onReason: onReason,
        gap: gap,
      );
      final laps = <_CaptureLap>[
        if (running && delayActive)
          _CaptureLap(
            id: 'current-delay',
            number: closedRecords + 2,
            action: 'Delay',
            reason: delayReason,
            cycle: selected == 'Planting' || selected == 'Walking'
                ? cycle
                : null,
            live: true,
            elapsed: () => recorder.needsReview
                ? null
                : delayStartMs == null
                ? recorder.delayMs
                : recorder.clock.monotonicMs - delayStartMs!,
          ),
        if (running && selected != null)
          _CaptureLap(
            id: 'current-activity',
            number: closedRecords + 1,
            action: selected!,
            cycle: selected == 'Planting' || selected == 'Walking'
                ? cycle
                : null,
            live: true,
            elapsed: () => recorder.needsReview
                ? null
                : actionStartMs == null
                ? recorder.actionMs
                : recorder.clock.monotonicMs - actionStartMs!,
          ),
        if (previousLap != null) previousLap!,
        for (final interval in recorder.recentIntervals)
          _CaptureLap(
            id: '${interval['number']}',
            number: interval['number'] as int?,
            action: '${interval['action']}',
            reason: interval['reason'] as String?,
            cycle: interval['cycle'] as int?,
            elapsed: () => interval['durationMs'] as int?,
          ),
      ].take(12).toList();
      final time = _DigitalTime(recorder: recorder, cycle: cycle, laps: laps);
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 16 : 20,
              8,
              compact ? 16 : 20,
              compact ? 8 : 12,
            ),
            child: Column(
              children: [
                Expanded(child: time),
                SizedBox(height: gap),
                SizedBox(
                  height: bottomHeight,
                  child: alert == null
                      ? grid
                      : bottomHeight < 240
                      ? Align(alignment: Alignment.bottomCenter, child: alert)
                      : Column(
                          children: [
                            alert,
                            Expanded(child: grid),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// Only live numeric readouts subscribe to display frames. Static labels,
/// inactive activities, controls and completed lap history are outside this boundary.
class _LiveReadout extends StatelessWidget {
  const _LiveReadout({
    required this.recorder,
    required this.live,
    required this.readout,
  });
  final ActionRecorder recorder;
  final bool live;
  final Widget Function() readout;
  @override
  Widget build(BuildContext context) {
    if (!live || !recorder.shouldRefreshDisplay) return readout();
    return RepaintBoundary(
      child: ValueListenableBuilder<int>(
        valueListenable: recorder.ticks,
        builder: (_, value, child) => readout(),
      ),
    );
  }
}

class _CaptureLap {
  const _CaptureLap({
    required this.id,
    required this.action,
    required this.elapsed,
    this.number,
    this.cycle,
    this.reason,
    this.live = false,
  });
  final String id, action;
  final int? number, cycle;
  final String? reason;
  final bool live;
  final int? Function() elapsed;
}

class _DigitalTime extends StatelessWidget {
  const _DigitalTime({
    required this.recorder,
    required this.cycle,
    required this.laps,
  });
  final ActionRecorder recorder;
  final int cycle;
  final List<_CaptureLap> laps;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
      final clockHeight = (bounds.maxWidth * .24).clamp(54.0, 112.0);
      final rowHeight = 28.0 * scale;
      final capacity = ((bounds.maxHeight - clockHeight - 44) / rowHeight)
          .floor()
          .clamp(2, 12);
      return Align(
        alignment: Alignment.topCenter,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: bounds.maxWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Expanded(child: SizedBox.shrink()),
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          'Total time',
                          style: TextStyle(
                            fontSize: 12,
                            color: _fieldMuted(context),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            cycle > 0 ? 'Cycle $cycle' : 'Cycle —',
                            key: const ValueKey('current-cycle'),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              fontFeatures: _figures,
                              color: _fieldMuted(context),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: _LiveReadout(
                    recorder: recorder,
                    live: recorder.running,
                    readout: () => Text(
                      captureTime(recorder.totalMs),
                      key: const ValueKey('total-time'),
                      style: TextStyle(
                        fontSize: 92,
                        height: 1.1,
                        fontWeight: FontWeight.w500,
                        fontFeatures: _figures,
                        color: _fieldInk(context),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                if (laps.isEmpty)
                  Row(
                    children: [
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Latest record',
                            style: TextStyle(
                              fontSize: 12,
                              color: _fieldMuted(context),
                            ),
                          ),
                        ),
                      ),
                      Text('—', style: TextStyle(color: _fieldMuted(context))),
                    ],
                  ),
                for (final lap in laps.take(capacity))
                  Padding(
                    key: ValueKey('recent-interval-${lap.id}'),
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Text(
                          lap.number == null
                              ? '—'
                              : '${lap.number}'.padLeft(2, '0'),
                          key: ValueKey('recent-number-${lap.id}'),
                          style: TextStyle(
                            fontSize: 14,
                            color: _fieldMuted(context),
                            fontFeatures: _figures,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          flex: 6,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Row(
                              children: [
                                Text(
                                  lap.action == 'Delay'
                                      ? 'Delay · ${lap.reason ?? 'Unspecified'}'
                                      : lap.action,
                                  key: ValueKey('recent-label-${lap.id}'),
                                  maxLines: 1,
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: lap.live
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                    color: lap.action == 'Delay'
                                        ? (Theme.of(context).brightness ==
                                                  Brightness.dark
                                              ? const Color(0xFFFFCF70)
                                              : const Color(0xFF8B6513))
                                        : lap.live
                                        ? _fieldAccent(context)
                                        : _fieldInk(context),
                                  ),
                                ),
                                if ((lap.cycle ?? 0) > 0) ...[
                                  const SizedBox(width: 6),
                                  Text(
                                    '· Cycle ${lap.cycle}',
                                    key: ValueKey('recent-cycle-${lap.id}'),
                                    maxLines: 1,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      color: _fieldMuted(context),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 4,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: _LiveReadout(
                                recorder: recorder,
                                live: lap.live,
                                readout: () => Text(
                                  captureTime(lap.elapsed()),
                                  key: ValueKey('recent-time-${lap.id}'),
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                    fontFeatures: _figures,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ValueListenableBuilder<int>(
                  valueListenable: recorder.sensorTicks,
                  builder: (_, value, child) =>
                      recorder.hasCurrentWalking &&
                          recorder.walking.distanceM != null
                      ? Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Walked ≈ ${recorder.walking.distanceM!.toStringAsFixed(1)} m${recorder.walking.gap ? ' · partial' : ''}',
                            style: TextStyle(
                              fontSize: 13,
                              color: _fieldMuted(context),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _ActivityGrid extends StatelessWidget {
  const _ActivityGrid({
    required this.recorder,
    required this.selected,
    required this.enabled,
    required this.running,
    required this.onSelect,
    required this.gap,
    required this.delayActive,
    required this.onReason,
    this.actionStartMs,
    this.activityDelayCount,
    this.totalsAtStart,
    this.delayStartMs,
    this.delayReason,
  });
  final ActionRecorder recorder;
  final String? selected, delayReason;
  final bool enabled, running, delayActive;
  final ValueChanged<String> onSelect, onReason;
  final double gap;
  final int? actionStartMs, delayStartMs;
  final int? activityDelayCount;
  final Map<String, int?>? totalsAtStart;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final compactReasons =
          bounds.maxHeight < 320 &&
          MediaQuery.orientationOf(context) == Orientation.landscape;
      final columns = compactReasons ? 4 : 2;
      final labelMeasure = TextPainter(
        text: TextSpan(
          text: 'Preparation',
          style: Theme.of(context).textTheme.labelLarge!.copyWith(
            fontSize: 26,
            fontWeight: FontWeight.w600,
            height: 1.15,
          ),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final contentWidth = labelMeasure.width.ceilToDouble();
      labelMeasure.dispose();
      final returning = running && selected == 'Walk out';
      bool allowed(String name) =>
          enabled &&
          (name == 'Preparation'
              ? returning
              : name == 'Walking'
              ? !returning
              : true);
      final delay = _DelayControl(
        recorder: recorder,
        active: delayActive,
        reason: delayReason,
        startMs: delayStartMs,
        enabled: enabled && running && selected != 'Delay',
        onToggle: () => onSelect('Delay'),
        onReason: onReason,
        parent: selected,
        delayCount: activityDelayCount ?? recorder.activityDelayCount,
      );
      const displayActions = ['Preparation', 'Walk out', 'Planting', 'Walking'];
      return Column(
        children: [
          for (var row = 0; row < 4 ~/ columns; row++) ...[
            Expanded(
              child: Row(
                children: [
                  for (var col = 0; col < columns; col++) ...[
                    if (col > 0) SizedBox(width: gap),
                    Expanded(
                      child: _ActivityButton(
                        recorder: recorder,
                        name: displayActions[row * columns + col],
                        contentWidth: contentWidth,
                        selected:
                            selected == displayActions[row * columns + col],
                        running: running,
                        totalsAtStart: totalsAtStart,
                        startMs: selected == displayActions[row * columns + col]
                            ? actionStartMs
                            : null,
                        delayCountOverride:
                            selected == displayActions[row * columns + col]
                            ? activityDelayCount
                            : null,
                        enabled: allowed(displayActions[row * columns + col]),
                        onSelect: onSelect,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(height: gap),
          ],
          Expanded(child: delay),
        ],
      );
    },
  );
}

class _ActivityButton extends StatelessWidget {
  const _ActivityButton({
    required this.recorder,
    required this.name,
    required this.contentWidth,
    required this.selected,
    required this.running,
    required this.enabled,
    required this.onSelect,
    this.startMs,
    this.delayCountOverride,
    this.totalsAtStart,
  });
  final ActionRecorder recorder;
  final String name;
  final double contentWidth;
  final bool selected, enabled, running;
  final ValueChanged<String> onSelect;
  final int? startMs;
  final int? delayCountOverride;
  final Map<String, int?>? totalsAtStart;
  @override
  Widget build(BuildContext context) {
    final delay = name == 'Delay';
    final paired = name == 'Planting' || name == 'Walking';
    final textScaler = MediaQuery.textScalerOf(context);
    final delays = delayCountOverride ?? recorder.displayDelayCount(name);
    return Semantics(
      selected: selected,
      hint: recorder.running ? 'Record $name' : 'Start $name',
      child: OutlinedButton(
        key: ValueKey('activity-$name'),
        onPressed: enabled ? () => onSelect(name) : null,
        style: OutlinedButton.styleFrom(
          animationDuration: Duration.zero,
          backgroundColor: selected
              ? delay
                    ? const Color(0xFFF1BB43)
                    : _blue
              : _fieldButton(context),
          disabledBackgroundColor: selected
              ? delay
                    ? const Color(0xFFF1BB43)
                    : _blue
              : _fieldDisabledButton(context),
          foregroundColor: selected && !delay
              ? const Color(0xFFFAFCFE)
              : _fieldInk(context),
          disabledForegroundColor: selected && !delay
              ? const Color(0xFFFAFCFE)
              : _fieldDisabledInk(context),
          side: BorderSide(
            color: selected
                ? delay
                      ? const Color(0xFFB38116)
                      : _blue
                : enabled
                ? _fieldOutline(context)
                : _fieldDisabledOutline(context),
            width: selected ? 2 : 1.3,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          alignment: Alignment.center,
        ),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: contentWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                      height: 1.15,
                    ),
                  ),
                  ...[
                    const SizedBox(height: 6),
                    _LiveReadout(
                      recorder: recorder,
                      live: selected && running,
                      readout: () {
                        final elapsed = paired && (!running || !selected)
                            ? 0
                            : startMs == null
                            ? recorder.displayMs(name)
                            : recorder.clock.monotonicMs - startMs!;
                        final frozenTotal = totalsAtStart?[name];
                        final total = totalsAtStart == null
                            ? recorder.cumulativeActivityMs(name)
                            : frozenTotal == null
                            ? null
                            : frozenTotal +
                                  (selected && running && startMs != null
                                      ? recorder.clock.monotonicMs - startMs!
                                      : 0);
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              height: textScaler.scale(20) * 1.1,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  captureTime(elapsed),
                                  key: ValueKey('activity-time-$name'),
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                    height: 1.1,
                                    fontFeatures: _figures,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            SizedBox(
                              height: textScaler.scale(12) * 1.2,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  'Total ${captureTime(total)}',
                                  key: ValueKey('activity-total-$name'),
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.2,
                                    fontFeatures: _figures,
                                    color: selected
                                        ? const Color(0xFFFAFCFE)
                                        : !enabled
                                        ? _fieldDisabledInk(context)
                                        : _fieldMuted(context),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    'Delays: $delays',
                    key: ValueKey('activity-delays-$name'),
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DelayControl extends StatelessWidget {
  const _DelayControl({
    required this.recorder,
    required this.active,
    required this.enabled,
    required this.onToggle,
    required this.onReason,
    this.reason,
    this.startMs,
    this.parent,
    this.delayCount = 0,
  });
  final ActionRecorder recorder;
  final bool active, enabled;
  final VoidCallback onToggle;
  final ValueChanged<String> onReason;
  final String? reason;
  final int? startMs;
  final String? parent;
  final int delayCount;
  int? get elapsedMs => startMs != null
      ? recorder.clock.monotonicMs - startMs!
      : active && !recorder.delayRunning
      ? 0
      : recorder.displayMs('Delay');
  @override
  Widget build(BuildContext context) {
    if (!active || reason != null || !enabled) {
      final label = active ? reason : recorder.lastDelayReason;
      return Semantics(
        selected: active,
        child: OutlinedButton(
          key: const ValueKey('activity-Delay'),
          onPressed: enabled ? onToggle : null,
          style: OutlinedButton.styleFrom(
            animationDuration: Duration.zero,
            backgroundColor: active
                ? const Color(0xFFF1BB43)
                : _fieldButton(context),
            disabledBackgroundColor: active
                ? const Color(0xFFF1BB43)
                : _fieldDisabledButton(context),
            foregroundColor: active
                ? const Color(0xFF19232E)
                : _fieldInk(context),
            disabledForegroundColor: active
                ? const Color(0xFF19232E)
                : _fieldDisabledInk(context),
            side: BorderSide(
              color: active
                  ? const Color(0xFFB38116)
                  : enabled
                  ? _fieldOutline(context)
                  : _fieldDisabledOutline(context),
              width: active ? 2 : 1.3,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.all(8),
          ),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Delay',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 6),
                  _LiveReadout(
                    recorder: recorder,
                    live: active,
                    readout: () => Text(
                      captureTime(elapsedMs),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        height: 1.1,
                        fontFeatures: _figures,
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(label ?? ' ', style: const TextStyle(fontSize: 11)),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, bounds) {
        const columns = 2;
        final reasonSize = bounds.maxHeight < 104 ? 16.0 : 20.0;
        final dark = Theme.of(context).brightness == Brightness.dark;
        return Semantics(
          key: const ValueKey('activity-Delay'),
          selected: true,
          explicitChildNodes: true,
          label:
              '${parent ?? recorder.action} · Delay $delayCount. Choose a reason',
          child: DecoratedBox(
            key: const ValueKey('delay-reason-picker'),
            decoration: BoxDecoration(
              color: _fieldButton(context),
              border: Border.all(color: const Color(0xFFB38116), width: 2),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                children: [
                  for (var row = 0; row < 4 ~/ columns; row++) ...[
                    if (row > 0) const SizedBox(height: 12),
                    Expanded(
                      child: Row(
                        children: [
                          for (var col = 0; col < columns; col++) ...[
                            if (col > 0) const SizedBox(width: 12),
                            Expanded(
                              child: Builder(
                                builder: (context) {
                                  final reason =
                                      delayReasons[row * columns + col];
                                  return Semantics(
                                    label: reason,
                                    button: true,
                                    excludeSemantics: true,
                                    onTap: () => onReason(reason),
                                    child: Tooltip(
                                      message: reason,
                                      child: OutlinedButton(
                                        key: ValueKey('delay-reason-$reason'),
                                        onPressed: () => onReason(reason),
                                        style: OutlinedButton.styleFrom(
                                          animationDuration: Duration.zero,
                                          backgroundColor: dark
                                              ? const Color(0xFF332A15)
                                              : const Color(0xFFFFF1CE),
                                          foregroundColor: dark
                                              ? const Color(0xFFFFD489)
                                              : const Color(0xFF19232E),
                                          minimumSize: Size.zero,
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          side: const BorderSide(
                                            color: Color(0xFFB38116),
                                          ),
                                        ),
                                        child: Center(
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: Text(
                                              reason,
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                fontSize: reasonSize,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AudioStatus extends StatelessWidget {
  const _AudioStatus({required this.recorder});
  final ActionRecorder recorder;
  @override
  Widget build(BuildContext context) {
    final recording = recorder.audioStatus == 'recording';
    final starting = recorder.audioStatus == 'requesting';
    final description = switch (recorder.audioStatus) {
      'recording' => 'Recording audio note',
      'requesting' => 'Starting microphone',
      'denied' => 'Microphone permission needed. Audio is not recording.',
      'unavailable' => 'Audio notes are available in the mobile app.',
      'interrupted' => 'Audio note interrupted. Audio is not recording.',
      _ => 'Audio note unavailable. Audio is not recording.',
    };
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = recording
        ? dark
              ? const Color(0xFFFFA4AC)
              : const Color(0xFFA21C32)
        : _fieldMuted(context);
    return Semantics(
      key: const ValueKey('audio-status'),
      label: description,
      liveRegion: true,
      excludeSemantics: true,
      child: Tooltip(
        message: description,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 112, maxHeight: 28),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: recording
                    ? dark
                          ? const Color(0xFF3D2025)
                          : const Color(0xFFFCE8EC)
                    : _fieldButton(context),
                border: Border.all(color: ink),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      recording ? Icons.mic : Icons.mic_off_outlined,
                      size: 16,
                      color: ink,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      recording
                          ? 'REC'
                          : starting
                          ? 'MIC…'
                          : 'MIC OFF',
                      style: TextStyle(
                        color: ink,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        height: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FitText extends StatelessWidget {
  const _FitText(
    this.text, {
    required this.style,
    this.alignment = Alignment.center,
  });
  final String text;
  final TextStyle style;
  final Alignment alignment;
  @override
  Widget build(BuildContext context) => Align(
    alignment: alignment,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: alignment,
      child: Text(text, style: style, textAlign: TextAlign.center),
    ),
  );
}

class _CaptureAlert extends StatelessWidget {
  const _CaptureAlert({
    required this.text,
    required this.label,
    required this.onTap,
  });
  final String text, label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 56,
    child: Row(
      children: [
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _FitText(
              text,
              alignment: Alignment.centerLeft,
              style: TextStyle(color: _fieldError(context), fontSize: 14),
            ),
          ),
        ),
        Expanded(
          flex: 2,
          child: TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                style: TextStyle(
                  color: _fieldError(context),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
