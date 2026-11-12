import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'action_journal.dart';
import 'capture_time.dart';
import 'delay_audio.dart';
import 'study_records.dart';

/// Study pages contain ten summaries; a timetable reads at most 31 intervals.
/// Covering capture stops display frames, not measurement or native sensors.
class SavedRecordsScreen extends StatefulWidget {
  const SavedRecordsScreen({
    super.key,
    required this.journal,
    required this.maxSequence,
    this.audio,
  });
  final ActionJournal journal;
  final int maxSequence;
  final DelayAudio? audio;
  @override
  State<SavedRecordsScreen> createState() => _SavedRecordsScreenState();
}

class _SavedRecordsScreenState extends State<SavedRecordsScreen> {
  final _scroll = ScrollController();
  final _positions = <StudyPosition?>[null];
  SavedStudyPage? _page;
  int _index = 0, _requested = 0;
  bool _loading = true, _failed = false;
  @override
  void initState() {
    super.initState();
    _load(0);
  }

  Future<void> _load(int index) async {
    setState(() {
      _requested = index;
      _loading = true;
      _failed = false;
    });
    try {
      final page = await readStudies(
        widget.journal,
        widget.maxSequence,
        position: _positions[index],
      );
      if (!mounted) return;
      setState(() {
        _page = page;
        _index = index;
        _loading = false;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  void _older() {
    final next = _page?.next;
    if (next == null || _loading) return;
    if (_positions.length == _index + 1) _positions.add(next);
    _load(_index + 1);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_loading,
    child: Scaffold(
      appBar: AppBar(title: const Text('Saved records')),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: _failed
                  ? _ReadFailure(onRetry: () => _load(_requested))
                  : _page == null
                  ? const SizedBox.shrink()
                  : _page!.studies.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('No studies recorded yet.'),
                      ),
                    )
                  : ListView.separated(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      itemCount: _page!.studies.length,
                      separatorBuilder: (_, index) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final study = _page!.studies[index];
                        final date =
                            study.recordedAt
                                ?.toLocal()
                                .toString()
                                .split('.')
                                .first ??
                            '';
                        return ListTile(
                          key: ValueKey('saved-study-${study.id}'),
                          enabled: !_loading,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 10,
                          ),
                          title: Text(
                            study.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            [
                              if (date.isNotEmpty) date,
                              captureTime(study.totalMs),
                            ].join(' · '),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => StudyTimetableScreen(
                                journal: widget.journal,
                                maxSequence: widget.maxSequence,
                                study: study,
                                audio: widget.audio,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (!_failed && _page != null)
              _RecordPages(
                index: _index,
                loading: _loading,
                hasOlder: _page!.next != null,
                onNewer: () => _load(_index - 1),
                onOlder: _older,
              ),
          ],
        ),
      ),
    ),
  );
}

class StudyTimetableScreen extends StatefulWidget {
  const StudyTimetableScreen({
    super.key,
    required this.journal,
    required this.maxSequence,
    required this.study,
    this.audio,
  });
  final ActionJournal journal;
  final int maxSequence;
  final SavedStudy study;
  final DelayAudio? audio;
  @override
  State<StudyTimetableScreen> createState() => _StudyTimetableScreenState();
}

class _StudyTimetableScreenState extends State<StudyTimetableScreen> {
  final _scroll = ScrollController();
  late final _audio = widget.audio ?? DelayAudio();
  late final _positions = <StudyPosition>[widget.study.position];
  StreamSubscription<Map<String, dynamic>>? _playback;
  StudyTimePage? _page;
  Set<String> _available = {};
  String? _playing, _playPending;
  int _index = 0, _requested = 0;
  bool _loading = true, _failed = false;
  @override
  void initState() {
    super.initState();
    _playback = _audio.playbackEvents.listen((event) {
      if (mounted && event['file'] == _playing) {
        setState(() => _playing = null);
        if (event['status'] == 'error') _notice();
      }
    }, onError: (Object _) {});
    _load(0);
  }

  Future<void> _load(int index) async {
    setState(() {
      _requested = index;
      _loading = true;
      _failed = false;
      _playing = null;
    });
    try {
      try {
        await _audio.stopPlayback();
      } catch (_) {
        /* Viewing records is independent of playback. */
      }
      final page = await readStudyTimes(
        widget.journal,
        widget.maxSequence,
        widget.study.id,
        position: _positions[index],
      );
      final available = await _audio.availableFiles(
        page.rows.map((row) => row.audioFile).whereType<String>().toSet(),
      );
      if (!mounted) return;
      setState(() {
        _page = page;
        _available = available;
        _index = index;
        _loading = false;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  void _older() {
    final next = _page?.next;
    if (next == null || _loading) return;
    if (_positions.length == _index + 1) _positions.add(next);
    _load(_index + 1);
  }

  void _notice() => ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('This audio note could not be played.')),
  );
  Future<void> _toggle(String file) async {
    if (_playPending != null || _loading) return;
    setState(() => _playPending = file);
    try {
      if (_playing == file) {
        await _audio.stopPlayback();
        if (mounted) setState(() => _playing = null);
      } else {
        await _audio.play(file);
        if (mounted) setState(() => _playing = file);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _playing = null);
        if (error is PlatformException && error.code == 'recording') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('End Delay before playing audio notes.'),
            ),
          );
        } else {
          _notice();
        }
      }
    } finally {
      if (mounted) setState(() => _playPending = null);
    }
  }

  @override
  void dispose() {
    unawaited(_playback?.cancel());
    unawaited(_audio.stopPlayback().catchError((Object _) {}));
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final study = widget.study;
    final rows = _page?.rows ?? const <StudyTimeRow>[];
    return PopScope(
      canPop: !_loading,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            study.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              if (_loading) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: CustomScrollView(
                  controller: _scroll,
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Recorded ${captureTime(study.totalMs)}',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (study.running)
                              Text('${study.action} is in progress.'),
                            const SizedBox(height: 4),
                            Text(
                              'Delay is included in activity time.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 40,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  'Cycle',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    'Activity',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 96,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    'Minutes',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(child: Divider(height: 1)),
                    if (_failed)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: _ReadFailure(onRetry: () => _load(_requested)),
                      )
                    else if (_page != null && rows.isEmpty)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('No completed activities yet.'),
                          ),
                        ),
                      )
                    else if (rows.isNotEmpty)
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        sliver: SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) => index.isOdd
                                ? const Divider(height: 1)
                                : _timeRow(rows[index ~/ 2]),
                            childCount: rows.length * 2 - 1,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (!_failed && _page != null)
                _RecordPages(
                  index: _index,
                  loading: _loading,
                  hasOlder: _page!.next != null,
                  onNewer: () => _load(_index - 1),
                  onOlder: _older,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _timeRow(StudyTimeRow row) {
    final color = row.isDelay
        ? Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFFFFCF70)
              : const Color(0xFF8B6513)
        : null;
    final file = row.audioFile;
    return Padding(
      key: ValueKey('time-row-${row.id}'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                '${row.cycle ?? '—'}',
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.action,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                if (row.isDelay)
                  Text(
                    row.reason ?? 'Unspecified',
                    style: TextStyle(fontSize: 13, color: color),
                  ),
                if (!row.isDelay && row.delayCount > 0)
                  Text(
                    'Delays: ${row.delayCount}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          if (row.isDelay && file != null && _available.contains(file))
            IconButton(
              key: ValueKey('play-note-${row.id}'),
              tooltip: _playing == file ? 'Stop note' : 'Play note',
              iconSize: 18,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              padding: EdgeInsets.zero,
              onPressed: !_loading && _playPending == null
                  ? () => _toggle(file)
                  : null,
              icon: Icon(
                _playing == file
                    ? Icons.stop_rounded
                    : Icons.play_arrow_rounded,
                color: color,
              ),
            ),
          const SizedBox(width: 8),
          SizedBox(
            width: 96,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    row.durationMs == null
                        ? '—'
                        : (row.durationMs! / 60000).toStringAsFixed(5),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    captureTime(row.durationMs),
                    style: const TextStyle(
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadFailure extends StatelessWidget {
  const _ReadFailure({required this.onRetry});
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Could not read saved records. The original is retained.'),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    ),
  );
}

class _RecordPages extends StatelessWidget {
  const _RecordPages({
    required this.index,
    required this.loading,
    required this.hasOlder,
    required this.onNewer,
    required this.onOlder,
  });
  final int index;
  final bool loading, hasOlder;
  final VoidCallback onNewer, onOlder;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
    child: Row(
      children: [
        Expanded(
          child: TextButton(
            key: const ValueKey('records-newer'),
            onPressed: !loading && index > 0 ? onNewer : null,
            child: const FittedBox(fit: BoxFit.scaleDown, child: Text('Newer')),
          ),
        ),
        SizedBox(
          width: 80,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('Page ${index + 1}'),
          ),
        ),
        Expanded(
          child: TextButton(
            key: const ValueKey('records-older'),
            onPressed: !loading && hasOlder ? onOlder : null,
            child: const FittedBox(fit: BoxFit.scaleDown, child: Text('Older')),
          ),
        ),
      ],
    ),
  );
}
