import 'dart:async';
import 'dart:io';
import 'package:field_tms/actions/action_journal.dart';
import 'package:field_tms/actions/coordinated_action_journal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'action_records_test.dart' show GatedJournal, event;

class ExclusiveJournal extends GatedJournal {
  bool reading = false;
  @override
  Future<ActionJournalPage> readPage({
    String? cursor,
    int limit = 50,
    required int maxSequence,
  }) async {
    reading = true;
    try {
      return await super.readPage(
        cursor: cursor,
        limit: limit,
        maxSequence: maxSequence,
      );
    } finally {
      reading = false;
    }
  }

  @override
  Future<void> append(Map<String, dynamic> event) {
    if (reading) throw StateError('File is being read.');
    return super.append(event);
  }
}

void main() {
  test(
    'automatic writes wait for a history read and survive a failed reader',
    () async {
      final source = ExclusiveJournal()..rows.add(event(1));
      final journal = CoordinatedActionJournal(source);
      source.readBarrier = Completer<void>();
      final read = journal.readPage(maxSequence: 1);
      await Future<void>.delayed(Duration.zero);
      final write = journal.append(event(2));
      await Future<void>.delayed(Duration.zero);
      expect(source.rows.length, 1);
      expect(source.reading, true);
      source.readBarrier!.complete();
      expect((await read).events.single['seq'], 1);
      await write;
      expect(source.rows.last['seq'], 2);
      source.failRead = true;
      source.readBarrier = Completer<void>();
      final failed = expectLater(
        journal.readPage(maxSequence: 2),
        throwsA(isA<FileSystemException>()),
      );
      final next = journal.append(event(3));
      source.readBarrier!.complete();
      await failed;
      await next;
      expect(source.rows.last['seq'], 3);
      await journal.close();
    },
  );
  test('cancelling a paused CSV stream releases queued writes', () async {
    final source = ExclusiveJournal()..rows.add(event(1));
    final journal = CoordinatedActionJournal(source);
    final first = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    subscription = journal.csv().listen((chunk) {
      subscription.pause();
      if (!first.isCompleted) first.complete();
    });
    await first.future;
    final write = journal.append(event(2));
    await Future<void>.delayed(Duration.zero);
    expect(source.rows.length, 1);
    await subscription.cancel();
    await write;
    expect(source.rows.length, 2);
    await journal.close();
  });
}
