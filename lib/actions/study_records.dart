import 'action_journal.dart';

/// A position inside one bounded journal page; no full-study event cache.
class StudyPosition {
  const StudyPosition({this.source, this.offset = 0, this.skipStudy});
  final String? source, skipStudy;
  final int offset;
}

class SavedStudy {
  SavedStudy(Map<String, dynamic> event, this.position)
    : id = (event['state'] as Map)['studyId'] as String,
      title = (event['state'] as Map)['title'] as String? ?? 'Field study',
      totalMs = event['totalMs'] as int? ?? 0,
      running = (event['state'] as Map)['running'] == true,
      action = (event['state'] as Map)['action'] as String? ?? '',
      recordedAt = DateTime.tryParse('${(event['boundary'] as Map)['utc']}');
  final String id, title, action;
  final int totalMs;
  final bool running;
  final DateTime? recordedAt;
  final StudyPosition position;
}

class SavedStudyPage {
  const SavedStudyPage(this.studies, {this.next});
  final List<SavedStudy> studies;
  final StudyPosition? next;
}

Future<SavedStudyPage> readStudies(
  ActionJournal journal,
  int maxSequence, {
  StudyPosition? position,
}) async {
  var source = position?.source;
  var offset = position?.offset ?? 0;
  var lastStudy = position?.skipStudy;
  final studies = <SavedStudy>[];
  while (true) {
    final page = await readActionPage(
      journal,
      cursor: source,
      maxSequence: maxSequence,
    );
    for (var i = offset; i < page.events.length; i++) {
      final event = page.events[i];
      final id = (event['state'] as Map)['studyId'] as String?;
      if (id == null || id.isEmpty || id == lastStudy) continue;
      if (studies.length == 10) {
        return SavedStudyPage(
          studies,
          next: StudyPosition(source: source, offset: i, skipStudy: lastStudy),
        );
      }
      studies.add(SavedStudy(event, StudyPosition(source: source, offset: i)));
      lastStudy = id;
    }
    source = page.nextCursor;
    offset = 0;
    if (source == null) return SavedStudyPage(studies);
  }
}

class StudyTimeRow {
  StudyTimeRow(this.id, Map interval)
    : action = interval['action'] as String? ?? '',
      cycle = interval['cycle'] as int?,
      durationMs = interval['durationMs'] as int?,
      reason = interval['reason'] as String?,
      parent = interval['parentActivity'] as String?,
      audioFile = interval['audioFile'] as String?,
      delayCount = interval['delayCount'] as int? ?? 0;
  final String id, action;
  final String? reason, parent, audioFile;
  final int? cycle, durationMs;
  final int delayCount;
  bool get isDelay => action == 'Delay';
}

class StudyTimePage {
  const StudyTimePage(this.rows, {this.next});
  final List<StudyTimeRow> rows;
  final StudyPosition? next;
}

Future<StudyTimePage> readStudyTimes(
  ActionJournal journal,
  int maxSequence,
  String studyId, {
  required StudyPosition position,
}) async {
  var source = position.source;
  var offset = position.offset;
  final rows = <StudyTimeRow>[];
  while (true) {
    final page = await readActionPage(
      journal,
      cursor: source,
      maxSequence: maxSequence,
    );
    for (var i = offset; i < page.events.length; i++) {
      final event = page.events[i];
      if ((event['state'] as Map)['studyId'] != studyId) {
        return StudyTimePage(rows);
      }
      if (event['closed'] is! Map && event['delayClosed'] is! Map) continue;
      if (rows.length >= 30) {
        return StudyTimePage(
          rows,
          next: StudyPosition(source: source, offset: i),
        );
      }
      for (final key in ['closed', 'delayClosed']) {
        final interval = event[key] as Map?;
        if (interval != null) {
          rows.add(StudyTimeRow('${event['seq']}-$key', interval));
        }
      }
    }
    source = page.nextCursor;
    offset = 0;
    if (source == null) return StudyTimePage(rows);
  }
}
