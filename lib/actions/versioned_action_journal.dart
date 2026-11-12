import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'action_journal.dart';
import 'action_journal_native.dart';

/// Keeps earlier CSV originals in place and appends to the current version.
/// All files stay locked; exports stream one current-format projection.
Future<ActionJournal> openVersionedActionJournal(Directory directory) async {
  final journals = <FileActionJournal>[];
  try {
    final manifest = File('${directory.path}/action-active.json');
    if (await manifest.exists()) {
      final data = jsonDecode(await manifest.readAsString()) as Map;
      final name = data['file'] as String;
      if (!RegExp(r'^action-reset-[0-9]+\.csv$').hasMatch(name)) {
        throw const FormatException('Invalid active journal.');
      }
      final active = File('${directory.path}/$name');
      if (!await active.exists()) {
        throw const FormatException(
          'Active journal is missing. Originals preserved.',
        );
      }
      journals.add(await FileActionJournal.open(active));
      final result = _VersionedJournal(journals, directory);
      await result._cleanup(data['retired'] as List? ?? []);
      return result;
    }
    var sequence = 0;
    var recent = <Map<String, dynamic>>[];
    for (var version = 1; version <= 4; version++) {
      final file = File('${directory.path}/action-events-v$version.csv');
      if (version < 4 && !await file.exists()) continue;
      final journal = await FileActionJournal.open(
        file,
        csvVersion: version,
        initialSequence: sequence,
        precedingRecent: recent,
      );
      journals.add(journal);
      sequence = journal.sequence;
      recent = await journal.recent();
    }
    return _VersionedJournal(journals, directory);
  } catch (_) {
    for (final journal in journals.reversed) {
      await journal.close();
    }
    rethrow;
  }
}

class _VersionedJournal implements PagedActionJournal, ResettableActionJournal {
  _VersionedJournal(this.journals, this.directory);
  final List<FileActionJournal> journals;
  final Directory directory;
  FileActionJournal get current => journals.last;
  bool _exporting = false;
  @override
  String get description => 'Live CSV on this device';
  @override
  Future<List<Map<String, dynamic>>> recent() => current.recent();
  @override
  Future<ActionJournalPage> readPage({
    String? cursor,
    int limit = 50,
    required int maxSequence,
  }) async {
    validateActionPage(limit, maxSequence);
    if (_exporting) throw StateError('Saved records are already being read.');
    _exporting = true;
    try {
      final token = cursor == null ? null : jsonDecode(cursor) as List;
      var source = token == null ? journals.length - 1 : token[0] as int;
      String? position = token == null ? null : token[1] as String?;
      if (source < 0 || source >= journals.length) {
        throw const FormatException('Invalid saved-record cursor.');
      }
      final rows = <Map<String, dynamic>>[];
      while (source >= 0 && rows.length < limit) {
        final page = await journals[source].readPage(
          cursor: position,
          limit: limit - rows.length,
          maxSequence: maxSequence,
        );
        rows.addAll(page.events);
        position = page.nextCursor;
        if (position == null) source--;
      }
      while (source >= 0 && !journals[source].hasRecords) {
        source--;
        position = null;
      }
      return ActionJournalPage(
        rows,
        nextCursor: source >= 0 ? jsonEncode([source, position]) : null,
      );
    } finally {
      _exporting = false;
    }
  }

  @override
  Future<void> append(Map<String, dynamic> event) {
    if (_exporting) throw StateError('CSV copy is being read.');
    return current.append(event);
  }

  Future<void> _cleanup(List retired) async {
    for (final name in retired) {
      if (name is! String ||
          !RegExp(
            r'^action-(events-v[1-4]|reset-[0-9]+)\.csv$',
          ).hasMatch(name)) {
        continue;
      }
      if (journals.any(
        (journal) => journal.file.path == '${directory.path}/$name',
      )) {
        continue;
      }
      final file = File('${directory.path}/$name');
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        /* A later opening retries committed cleanup. */
      }
    }
  }

  @override
  Future<void> resetStudy(
    String studyId,
    Map<String, dynamic> replacement,
  ) async {
    if (_exporting) throw StateError('Saved records are being read.');
    _exporting = true;
    FileActionJournal? prepared;
    var committed = false;
    final name = 'action-reset-${DateTime.now().microsecondsSinceEpoch}.csv';
    final file = File('${directory.path}/$name');
    final manifest = File('${directory.path}/action-active.json');
    final staging = File('${directory.path}/action-active.pending');
    try {
      final writer = await file.open(mode: FileMode.write);
      try {
        await writer.writeString(actionCsvHeader);
        var sequence = 0;
        Map<String, dynamic> resequence(Map<String, dynamic> original) {
          final event = Map<String, dynamic>.from(
            jsonDecode(jsonEncode(original)) as Map,
          );
          event['seq'] = ++sequence;
          (event['state'] as Map)['seq'] = sequence;
          return event;
        }

        for (final source in journals) {
          var header = true;
          await for (final line
              in source
                  .csv()
                  .cast<List<int>>()
                  .transform(utf8.decoder)
                  .transform(const LineSplitter())) {
            if (header) {
              header = false;
              continue;
            }
            final event = decodeActionEvent(line);
            if ((event['state'] as Map)['studyId'] != studyId) {
              await writer.writeString(encodeActionEvent(resequence(event)));
            }
          }
        }
        await writer.writeString(encodeActionEvent(resequence(replacement)));
        await writer.flush();
      } finally {
        await writer.close();
      }
      prepared = await FileActionJournal.open(file);
      final retired = [
        for (final old in journals) old.file.uri.pathSegments.last,
      ];
      if (await manifest.exists()) {
        retired.addAll(
          ((jsonDecode(await manifest.readAsString()) as Map)['retired']
                  as List)
              .cast<String>(),
        );
      }
      await staging.writeAsString(
        jsonEncode({'file': name, 'retired': retired.toSet().toList()}),
        flush: true,
      );
      await staging.rename(manifest.path);
      committed = true;
      final old = List<FileActionJournal>.of(journals);
      journals
        ..clear()
        ..add(prepared);
      prepared = null;
      for (final source in old.reversed) {
        try {
          await source.close();
        } catch (_) {
          /* New journal is already committed. */
        }
      }
      await _cleanup(retired);
    } finally {
      await prepared?.close();
      if (!committed && await file.exists()) await file.delete();
      _exporting = false;
    }
  }

  @override
  Stream<Uint8List> csv() async* {
    if (_exporting) throw StateError('A CSV copy is already being read.');
    _exporting = true;
    try {
      yield Uint8List.fromList(utf8.encode(actionCsvHeader));
      for (final source in journals) {
        if (source.csvVersion == 4) {
          // Current rows are already validated at open/append. Stream their
          // original bytes without JSON/base64/CRC re-encoding each record.
          var skip = utf8.encode(actionCsvHeader).length;
          await for (final chunk in source.csv()) {
            final start = skip.clamp(0, chunk.length);
            skip -= start;
            if (start < chunk.length) yield Uint8List.sublistView(chunk, start);
          }
          continue;
        }
        var header = true;
        await for (final line
            in source
                .csv()
                .cast<List<int>>()
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
          if (header) {
            header = false;
            continue;
          }
          yield Uint8List.fromList(
            utf8.encode(encodeActionEvent(decodeActionEvent(line))),
          );
        }
      }
    } finally {
      _exporting = false;
    }
  }

  @override
  Future<void> close() async {
    Object? failure;
    StackTrace? trace;
    for (final journal in journals.reversed) {
      try {
        await journal.close();
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, trace!);
  }
}
