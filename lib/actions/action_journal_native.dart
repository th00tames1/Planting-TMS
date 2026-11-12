import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'action_journal.dart';

/// Append-only CSV with bounded recovery memory, an exclusive writer lock,
/// CRC validation and fsync before acknowledgement. Only a non-newline tail
/// may be repaired; a complete corrupt record blocks capture visibly.
class FileActionJournal implements PagedActionJournal {
  FileActionJournal._(
    this.file,
    this._handle,
    this.csvVersion,
    this._initialSequence,
    this._precedingRecent,
  );
  final File file;
  final RandomAccessFile _handle;
  final int csvVersion, _initialSequence;
  final List<Map<String, dynamic>> _precedingRecent;
  int get sequence => _sequence;
  bool get hasRecords => _sequence > _initialSequence;
  List<Map<String, dynamic>> _recent = [];
  int _sequence = 0;
  int repairedBytes = 0;
  bool _needsScan = false;
  bool _exporting = false;

  static Future<FileActionJournal> open(
    File file, {
    int csvVersion = 4,
    int initialSequence = 0,
    List<Map<String, dynamic>> precedingRecent = const [],
  }) async {
    await file.parent.create(recursive: true);
    final handle = await file.open(mode: FileMode.append);
    final journal = FileActionJournal._(
      file,
      handle,
      csvVersion,
      initialSequence,
      List.of(precedingRecent),
    );
    try {
      await handle.lock(FileLock.exclusive);
      if (await handle.length() == 0) {
        await handle.writeFrom(utf8.encode(actionCsvHeaderFor(csvVersion)));
        await handle.flush();
      }
      await journal._scan();
      return journal;
    } catch (_) {
      await handle.close();
      rethrow;
    }
  }

  Future<void> _scan() async {
    await _handle.setPosition(0);
    var pending = <int>[];
    var acceptedBytes = 0;
    var header = false;
    var sequence = _initialSequence;
    final recent = List<Map<String, dynamic>>.of(_precedingRecent);
    while (true) {
      final chunk = await _handle.read(32768);
      if (chunk.isEmpty) break;
      for (final byte in chunk) {
        pending.add(byte);
        if (pending.length > 65536) {
          throw const FormatException('Journal row exceeds safety limit.');
        }
        if (byte != 10) continue;
        final line = utf8.decode(pending.sublist(0, pending.length - 1));
        if (!header) {
          if ('$line\n' != actionCsvHeaderFor(csvVersion)) {
            throw const FormatException('Unknown CSV journal header.');
          }
          header = true;
        } else {
          final event = decodeActionEvent(line);
          if (event['seq'] != sequence + 1) {
            throw const FormatException('Journal sequence is incomplete.');
          }
          sequence++;
          recent.add(event);
          if (recent.length > 20) recent.removeAt(0);
        }
        acceptedBytes += pending.length;
        pending = [];
      }
    }
    if (!header) {
      throw const FormatException(
        'Incomplete journal header. Original file preserved.',
      );
    }
    if (pending.isNotEmpty) {
      repairedBytes += pending.length;
      await _handle.truncate(acceptedBytes);
      await _handle.flush();
    }
    await _handle.setPosition(acceptedBytes);
    _recent = recent;
    _sequence = sequence;
  }

  @override
  Future<List<Map<String, dynamic>>> recent() async => List.of(_recent);

  @override
  Future<ActionJournalPage> readPage({
    String? cursor,
    int limit = 50,
    required int maxSequence,
  }) async {
    validateActionPage(limit, maxSequence);
    if (_exporting) throw StateError('Saved records are already being read.');
    _exporting = true;
    int? length;
    try {
      length = await _handle.length();
      final headerLength = utf8.encode(actionCsvHeaderFor(csvVersion)).length;
      var end = cursor == null ? length : int.parse(cursor);
      if (end < headerLength || end > length) {
        throw const FormatException('Invalid saved-record cursor.');
      }
      final rows = <Map<String, dynamic>>[];
      while (end > headerLength && rows.length < limit) {
        final row = await _previousLine(end, headerLength);
        end = row.start;
        final event = decodeActionEvent(row.line);
        if ((event['seq'] as int) <= maxSequence) rows.add(event);
      }
      return ActionJournalPage(
        rows,
        nextCursor: end > headerLength ? '$end' : null,
      );
    } finally {
      try {
        if (length != null) await _handle.setPosition(length);
      } finally {
        _exporting = false;
      }
    }
  }

  // Read backwards through the existing locked handle. A second file handle
  // cannot read this journal on Windows. Only one bounded row is assembled.
  Future<({int start, String line})> _previousLine(
    int end,
    int headerLength,
  ) async {
    await _handle.setPosition(end - 1);
    if ((await _handle.read(1)).single != 10) {
      throw const FormatException('Incomplete saved record.');
    }
    var position = end - 1;
    final parts = <Uint8List>[];
    var size = 0;
    while (position > headerLength) {
      final start = position - 4096 < headerLength
          ? headerLength
          : position - 4096;
      await _handle.setPosition(start);
      final chunk = await _handle.read(position - start);
      if (chunk.length != position - start) {
        throw const FormatException('Saved record ended unexpectedly.');
      }
      final separator = chunk.lastIndexOf(10);
      final part = Uint8List.sublistView(chunk, separator + 1);
      size += part.length;
      if (size + 1 > 65536) {
        throw const FormatException('Journal row exceeds safety limit.');
      }
      parts.add(part);
      if (separator >= 0 || start == headerLength) {
        final bytes = BytesBuilder(copy: false);
        for (final part in parts.reversed) {
          bytes.add(part);
        }
        return (
          start: start + separator + 1,
          line: utf8.decode(bytes.takeBytes()),
        );
      }
      position = start;
    }
    throw const FormatException('Empty saved record.');
  }

  @override
  Future<void> append(Map<String, dynamic> event) async {
    if (_exporting) throw StateError('CSV copy is being read.');
    if (_needsScan) {
      await _scan();
      _needsScan = false;
    }
    final line = encodeActionEvent(event, csvVersion: csvVersion);
    // Retry after an ambiguous write/flush result first reconciles the actual
    // file. A fully written event is flushed again, never duplicated.
    if (event['seq'] != _sequence + 1) {
      final last = _recent.lastOrNull;
      if (last != null &&
          encodeActionEvent(last, csvVersion: csvVersion) == line) {
        await _handle.flush();
        return;
      }
      throw StateError('Journal event sequence conflict.');
    }
    try {
      await _handle.writeFrom(utf8.encode(line));
      await _handle.flush();
      _sequence++;
      _recent.add(event);
      if (_recent.length > 20) _recent.removeAt(0);
    } catch (_) {
      // The caller keeps the immutable event and offers an explicit retry.
      // Rescan validates a complete append or truncates only its torn tail.
      _needsScan = true;
      await _scan();
      _needsScan = false;
      rethrow;
    }
  }

  @override
  Stream<Uint8List> csv() async* {
    if (_exporting) throw StateError('A CSV copy is already being read.');
    _exporting = true;
    final length = await _handle.length();
    try {
      await _handle.setPosition(0);
      var remaining = length;
      while (remaining > 0) {
        final chunk = await _handle.read(remaining > 32768 ? 32768 : remaining);
        if (chunk.isEmpty) throw StateError('CSV copy ended unexpectedly.');
        remaining -= chunk.length;
        yield chunk;
      }
    } finally {
      await _handle.setPosition(length);
      _exporting = false;
    }
  }

  @override
  String get description => 'Live CSV on this device';
  @override
  Future<void> close() => _handle.close();
}
