import 'package:flutter/material.dart';

import 'action_journal.dart';
import 'capture_time.dart';
import 'delay_audio.dart';

/// Reads the capture original in bounded pages. Covering the stopwatch stops
/// display ticks, not measurement. Leave only after the file read has finished.
class SavedRecordsScreen extends StatefulWidget {
  const SavedRecordsScreen({
    super.key,
    required this.journal,
    required this.maxSequence,
  });
  final ActionJournal journal;
  final int maxSequence;

  @override
  State<SavedRecordsScreen> createState() => _SavedRecordsScreenState();
}

class _SavedRecordsScreenState extends State<SavedRecordsScreen> {
  final _scroll = ScrollController();
  final _cursors = <String?>[null];
  ActionJournalPage? _page;
  int _index = 0;
  int _requestedIndex = 0;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load(0);
  }

  Future<void> _load(int index) async {
    setState(() {
      _requestedIndex = index;
      _loading = true;
      _failed = false;
    });
    try {
      final page = await readActionPage(
        widget.journal,
        cursor: _cursors[index],
        maxSequence: widget.maxSequence,
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

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _older() {
    final next = _page?.nextCursor;
    if (_loading || next == null) return;
    if (_cursors.length == _index + 1) _cursors.add(next);
    _load(_index + 1);
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
            Expanded(child: _body()),
            if (!_failed && _page != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        key: const ValueKey('records-newer'),
                        onPressed: !_loading && _index > 0
                            ? () => _load(_index - 1)
                            : null,
                        child: const Text('Newer'),
                      ),
                    ),
                    Text('Page ${_index + 1}'),
                    Expanded(
                      child: TextButton(
                        key: const ValueKey('records-older'),
                        onPressed: !_loading && _page!.nextCursor != null
                            ? _older
                            : null,
                        child: const Text('Older'),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );

  Widget _body() {
    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Could not read saved records. The original is retained.',
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => _load(_requestedIndex),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    final page = _page;
    if (page == null) return const SizedBox.shrink();
    if (page.events.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No saved records yet. Tap an activity to start a study.',
          ),
        ),
      );
    }
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: page.events.length,
      separatorBuilder: (_, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final event = page.events[index];
        final boundary = event['boundary'] as Map;
        final utc = DateTime.tryParse('${boundary['utc']}');
        final local = utc?.toLocal().toString().split('.').first;
        final details = <String>[
          '#${event['seq']} · ${local ?? boundary['utc']}',
          if ((event['closed'] as Map?)?['durationMs'] case final int ms)
            '${(ms / 60000).toStringAsFixed(5)} min',
          if (event['delayClosed'] case final Map delay)
            'Delay · ${delay['reason'] ?? 'Unspecified'} · ${captureTime(delay['durationMs'] as int?)}',
        ];
        return ListTile(
          key: ValueKey('saved-record-${event['seq']}'),
          enabled: !_loading,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 8,
          ),
          title: Text(
            _recordTitle(event),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(details.join('\n')),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => _RecordDetails(event: event),
            ),
          ),
        );
      },
    );
  }
}

String _recordTitle(Map<String, dynamic> event) {
  final closed = event['closed'] as Map?;
  if (closed != null) {
    final cycle = closed['cycle'] as int?;
    return '${closed['action']}${cycle == null ? '' : ' · Cycle $cycle'} · ${captureTime(closed['durationMs'] as int?)}';
  }
  final state = event['state'] as Map;
  final action = state['action'];
  return switch (event['kind']) {
    'start' => '$action started',
    'delay_start' => 'Delay started',
    'delay_reason' =>
      'Delay · ${(state['delay'] as Map?)?['reason'] ?? 'Unspecified'}',
    'delay_end' => 'Delay ended',
    'repeat' => '$action · repeated tap',
    'recovered' => 'Study recovered',
    'new_study' => 'New study',
    'stop' => 'Study stopped',
    'action' => '$action selected',
    'interrupted' => 'Interrupted activity closed',
    _ => '${event['kind']}'.replaceAll('_', ' '),
  };
}

class _RecordDetails extends StatefulWidget {
  const _RecordDetails({required this.event});
  final Map<String, dynamic> event;
  @override
  State<_RecordDetails> createState() => _RecordDetailsState();
}

class _RecordDetailsState extends State<_RecordDetails> {
  final _audio = DelayAudio();
  bool _playing = false;
  Map<String, dynamic> get event => widget.event;
  @override
  void dispose() {
    _audio.stopPlayback();
    super.dispose();
  }

  Future<void> _play(String file) async {
    try {
      if (_playing) {
        await _audio.stopPlayback();
      } else {
        await _audio.play(file);
      }
      if (mounted) setState(() => _playing = !_playing);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This audio note is unavailable.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final values = actionEventFields(event);
    final audioFile = values['audio_file'];
    const first = [
      'action',
      'duration_seconds',
      'decimal_minutes',
      'cycle',
      'activity_delay_count',
      'delay_reason',
      'delay_parent_activity',
      'delay_duration_seconds',
      'delay_decimal_minutes',
      'delay_cycle',
      'delay_ordinal',
      'event_utc',
    ];
    final fields = [
      for (final key in first) MapEntry(key, values[key]!),
      ...values.entries.where((field) => !first.contains(field.key)),
    ];
    return Scaffold(
      appBar: AppBar(title: Text('Record #${event['seq']}')),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        itemCount: fields.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _recordTitle(event),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (audioFile != null && audioFile.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: () => _play(audioFile),
                      icon: Icon(
                        _playing
                            ? Icons.stop_rounded
                            : Icons.play_arrow_rounded,
                      ),
                      label: Text(_playing ? 'Stop audio' : 'Play note'),
                    ),
                  ],
                ],
              ),
            );
          }
          final field = fields[index - 1];
          final label = field.key
              .replaceAll('_', ' ')
              .replaceAll('utc', 'UTC')
              .replaceAll('gps', 'GPS');
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${label[0].toUpperCase()}${label.substring(1)}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 3),
                Text(field.value.isEmpty ? '—' : field.value),
              ],
            ),
          );
        },
      ),
    );
  }
}
