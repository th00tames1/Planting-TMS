import 'dart:convert';
import 'dart:typed_data';

/// The journal is the capture original. An acknowledgement means the entire
/// event, its closed interval and the resulting state are durable together.
abstract class ActionJournal {
  Future<List<Map<String, dynamic>>> recent();
  Future<void> append(Map<String, dynamic> event);
  Stream<Uint8List> csv();
  Future<void> close();
  String get description;
}

/// Atomic replacement used only after an explicit destructive Reset confirmation.
abstract interface class ResettableActionJournal implements ActionJournal {
  Future<void> resetStudy(String studyId, Map<String, dynamic> replacement);
}

/// A bounded, newest-first view of the original journal. Cursors belong to the
/// journal that returned them; the accepted sequence freezes a reader's view.
class ActionJournalPage {
  const ActionJournalPage(this.events, {this.nextCursor});
  final List<Map<String, dynamic>> events;
  final String? nextCursor;
}

abstract interface class PagedActionJournal implements ActionJournal {
  Future<ActionJournalPage> readPage({
    String? cursor,
    int limit = 50,
    required int maxSequence,
  });
}

void validateActionPage(int limit, int maxSequence) {
  if (limit < 1 || limit > 100 || maxSequence < 0) {
    throw ArgumentError('Invalid saved-record page.');
  }
}

/// Streaming compatibility for injected journals. Device journals implement
/// direct paging, so viewing old records does not scan a working day's file.
Future<ActionJournalPage> readActionPage(
  ActionJournal journal, {
  String? cursor,
  int limit = 50,
  required int maxSequence,
}) async {
  validateActionPage(limit, maxSequence);
  if (journal is PagedActionJournal) {
    return journal.readPage(
      cursor: cursor,
      limit: limit,
      maxSequence: maxSequence,
    );
  }
  final before = cursor == null ? maxSequence + 1 : int.parse(cursor);
  final rows = <Map<String, dynamic>>[];
  var header = true;
  await for (final line
      in journal
          .csv()
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
    if (header) {
      header = false;
      continue;
    }
    final event = decodeActionEvent(line);
    if ((event['seq'] as int) >= before || event['seq'] > maxSequence) continue;
    rows.add(event);
    if (rows.length > limit + 1) rows.removeAt(0);
  }
  final hasOlder = rows.length > limit;
  if (hasOlder) rows.removeAt(0);
  final page = rows.reversed.toList();
  return ActionJournalPage(
    page,
    nextCursor: hasOlder ? '${page.last['seq']}' : null,
  );
}

/// The same readable values as a current-format CSV copy, without the internal
/// recovery payload or checksum. Legacy values remain empty when unknown.
Map<String, String> actionEventFields(Map<String, dynamic> event) {
  final cells = RegExp(r'"((?:[^"]|"")*)"(?:,|$)')
      .allMatches(encodeActionEvent(event).trimRight())
      .map((match) => match[1]!.replaceAll('""', '"'))
      .toList();
  return {
    for (var i = 0; i < actionCsvColumns.length - 2; i++)
      actionCsvColumns[i]: cells[i],
  };
}

const actionCsvColumnsV1 = <String>[
  'schema',
  'sequence',
  'study_id',
  'event',
  'event_utc',
  'event_elapsed_realtime_ms',
  'action',
  'action_start_utc',
  'action_end_utc',
  'duration_ms',
  'duration_seconds',
  'decimal_minutes',
  'start_latitude',
  'start_longitude',
  'start_accuracy_m',
  'start_fix_utc',
  'start_fix_age_ms',
  'start_location_status',
  'end_latitude',
  'end_longitude',
  'end_accuracy_m',
  'end_fix_utc',
  'end_fix_age_ms',
  'end_location_status',
  'event_latitude',
  'event_longitude',
  'event_accuracy_m',
  'event_fix_utc',
  'event_fix_age_ms',
  'event_location_status',
  'next_action',
  'total_elapsed_ms',
  'walking_steps',
  'walking_distance_m_estimated',
  'payload_base64',
  'crc32',
];
final actionCsvColumnsV2 = <String>[
  ...actionCsvColumnsV1.take(actionCsvColumnsV1.length - 2),
  'delay_event',
  'delay_reason',
  'delay_parent_activity',
  'delay_is_overlap',
  'delay_start_utc',
  'delay_end_utc',
  'delay_duration_ms',
  'delay_duration_seconds',
  'delay_decimal_minutes',
  'delay_reason_recorded_utc',
  'delay_start_latitude',
  'delay_start_longitude',
  'delay_start_accuracy_m',
  'delay_start_fix_utc',
  'delay_start_fix_age_ms',
  'delay_start_location_status',
  'delay_end_latitude',
  'delay_end_longitude',
  'delay_end_accuracy_m',
  'delay_end_fix_utc',
  'delay_end_fix_age_ms',
  'delay_end_location_status',
  'payload_base64',
  'crc32',
];
final actionCsvColumnsV3 = <String>[
  ...actionCsvColumnsV2.take(actionCsvColumnsV2.length - 2),
  'cycle',
  'activity_delay_count',
  'delay_cycle',
  'delay_ordinal',
  'payload_base64',
  'crc32',
];
final actionCsvColumns = <String>[
  ...actionCsvColumnsV3.take(actionCsvColumnsV3.length - 2),
  'study_title',
  'audio_file',
  'audio_status',
  'audio_started_utc',
  'audio_ended_utc',
  'payload_base64',
  'crc32',
];

String _cell(Object? value) =>
    '"${(value ?? '').toString().replaceAll('"', '""')}"';
String actionCsvHeaderFor(int version) =>
    '${(version == 1
        ? actionCsvColumnsV1
        : version == 2
        ? actionCsvColumnsV2
        : version == 3
        ? actionCsvColumnsV3
        : actionCsvColumns).map(_cell).join(',')}\n';
String get actionCsvHeader => actionCsvHeaderFor(4);

List<Object?> _location(Map? boundary) {
  final fix = boundary?['location'] as Map?;
  return [
    for (final key in [
      'latitude',
      'longitude',
      'accuracyM',
      'fixUtc',
      'ageMs',
      'status',
    ])
      fix?[key],
  ];
}

/// All records occupy one physical line. Text fields may not contain newlines;
/// the recovery payload is base64, so a torn tail is unambiguous.
String encodeActionEvent(Map<String, dynamic> event, {int csvVersion = 4}) {
  final payload = utf8.encode(jsonEncode(event));
  final state = event['state'] as Map;
  final boundary = event['boundary'] as Map;
  final closed = event['closed'] as Map?;
  final duration = closed?['durationMs'] as int?;
  final delayClosed = event['delayClosed'] as Map?;
  final delay = delayClosed ?? state['delay'] as Map?;
  final delayDuration = delayClosed?['durationMs'] as int?;
  final audio = event['audioNote'] as Map?;
  final values = <Object?>[
    csvVersion,
    event['seq'],
    state['studyId'],
    event['kind'],
    boundary['utc'],
    boundary['monoMs'],
    closed?['action'],
    (closed?['start'] as Map?)?['utc'],
    (closed?['end'] as Map?)?['utc'],
    duration,
    duration == null ? null : (duration / 1000).toStringAsFixed(3),
    duration == null ? null : (duration / 60000).toStringAsFixed(9),
    ..._location(closed?['start'] as Map?),
    ..._location(closed?['end'] as Map?),
    ..._location(boundary),
    state['running'] == true ? state['action'] : null,
    event['totalMs'],
    (boundary['motion'] as Map?)?['steps'],
    (boundary['motion'] as Map?)?['distanceM'],
    if (csvVersion >= 2) ...[
      delay == null
          ? null
          : delayClosed != null
          ? 'end'
          : event['kind'],
      delay == null ? null : delay['reason'] ?? 'Unspecified',
      delay?['parentActivity'],
      delay == null ? null : true,
      (delay?['start'] as Map?)?['utc'],
      (delayClosed?['end'] as Map?)?['utc'],
      delayDuration,
      delayDuration == null ? null : (delayDuration / 1000).toStringAsFixed(3),
      delayDuration == null ? null : (delayDuration / 60000).toStringAsFixed(9),
      (delay?['reasonAt'] as Map?)?['utc'],
      ..._location(delay?['start'] as Map?),
      ..._location(delayClosed?['end'] as Map?),
    ],
    if (csvVersion >= 3) ...[
      closed == null ? state['cycle'] : closed['cycle'],
      closed == null ? state['activeDelayCount'] : closed['delayCount'],
      delay?['cycle'],
      delay?['ordinal'],
    ],
    if (csvVersion >= 4) ...[
      state['title'],
      audio?['file'] ?? delay?['audioFile'],
      audio?['status'] ?? (delay?['audioFile'] == null ? null : 'requested'),
      audio?['startedUtc'],
      audio?['endedUtc'],
    ],
    base64Encode(payload),
    _crc(payload).toRadixString(16).padLeft(8, '0'),
  ];
  if (values.any((v) => v.toString().contains(RegExp(r'[\r\n]')))) {
    throw const FormatException('Journal cells must occupy one line.');
  }
  final line = '${values.map(_cell).join(',')}\n';
  if (utf8.encode(line).length > 65536) {
    throw const FormatException('Event is too large.');
  }
  return line;
}

Map<String, dynamic> decodeActionEvent(String line) {
  final cells = <String>[];
  final matches = RegExp(r'"((?:[^"]|"")*)"(?:,|$)').allMatches(line);
  var end = 0;
  for (final match in matches) {
    if (match.start != end) throw const FormatException('Invalid CSV record.');
    cells.add(match[1]!.replaceAll('""', '"'));
    end = match.end;
  }
  final version = cells.length == actionCsvColumnsV1.length
      ? 1
      : cells.length == actionCsvColumnsV2.length
      ? 2
      : cells.length == actionCsvColumnsV3.length
      ? 3
      : 4;
  if (end != line.length ||
      cells.length !=
          (version == 1
              ? actionCsvColumnsV1.length
              : version == 2
              ? actionCsvColumnsV2.length
              : version == 3
              ? actionCsvColumnsV3.length
              : actionCsvColumns.length)) {
    throw const FormatException('Invalid CSV column count.');
  }
  final bytes = base64Decode(cells[cells.length - 2]);
  if (_crc(bytes).toRadixString(16).padLeft(8, '0') != cells.last) {
    throw const FormatException(
      'Journal checksum failed. Original file preserved.',
    );
  }
  final event = Map<String, dynamic>.from(
    jsonDecode(utf8.decode(bytes)) as Map,
  );
  if (encodeActionEvent(event, csvVersion: version) != '$line\n') {
    throw const FormatException(
      'Journal columns disagree with original payload.',
    );
  }
  return event;
}

int _crc(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >>> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
