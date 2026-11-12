@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;
import 'package:field_tms/actions/action_journal.dart';
import 'package:field_tms/actions/action_journal_web.dart';

Map<String, dynamic> event(int sequence) => {
  'seq': sequence,
  'kind': 'repeat',
  'boundary': {'utc': '2026-11-09T00:00:00Z', 'monoMs': sequence * 1000},
  'totalMs': sequence * 1000,
  'state': {
    'seq': sequence,
    'running': false,
    'studyId': 'browser-fixture',
    'cycle': 1,
  },
};

Future<void> seedExistingSchema(String name, int count) async {
  final ready = Completer<void>();
  final request = web.window.indexedDB.open(name, 2);
  request.onupgradeneeded = ((web.Event _) {
    final database = request.result as web.IDBDatabase;
    for (final store in [
      'session_snapshots',
      'session_records',
      'study_sessions',
      'record_originals',
    ]) {
      database.createObjectStore(store);
    }
  }).toJS;
  request.onsuccess = ((web.Event _) {
    final database = request.result as web.IDBDatabase;
    final tx = database.transaction(
      ['session_snapshots'.toJS, 'session_records'.toJS].toJS,
      'readwrite',
    );
    for (var i = 1; i <= count; i++) {
      tx
          .objectStore('session_records')
          .add(jsonEncode(event(i)).toJS, ['legacy-v1', i].jsify());
    }
    tx
        .objectStore('session_snapshots')
        .put(
          jsonEncode({'seq': count, 'event': event(count)}).toJS,
          'legacy-v1'.toJS,
        );
    tx.oncomplete = ((web.Event _) {
      database.close();
      ready.complete();
    }).toJS;
    tx.onabort = ((web.Event _) {
      database.close();
      ready.completeError(StateError('Fixture failed'));
    }).toJS;
  }).toJS;
  request.onerror = ((web.Event _) => ready.completeError(
    StateError('Fixture failed'),
  )).toJS;
  await ready.future;
}

void main() {
  var fixture = 0;
  String ownedName() {
    final name =
        'field-actions-owned-test-${DateTime.now().microsecondsSinceEpoch}-${fixture++}';
    addTearDown(() async {
      final done = Completer<void>();
      final request = web.window.indexedDB.deleteDatabase(name);
      request.onsuccess = ((web.Event _) => done.complete()).toJS;
      request.onerror = ((web.Event _) => done.completeError(
        StateError('Cleanup failed'),
      )).toJS;
      await done.future;
    });
    return name;
  }

  test(
    'existing activity records survive store separation and bounded paging',
    () async {
      final name = ownedName();
      await seedExistingSchema(name, 125);
      final journal = await BrowserActionJournal.open(databaseName: name);
      addTearDown(journal.close);
      final original = <int>[];
      String? cursor;
      do {
        final page = await journal.readPage(cursor: cursor, maxSequence: 125);
        expect(page.events.length, lessThanOrEqualTo(50));
        original.addAll(page.events.map((e) => e['seq'] as int));
        cursor = page.nextCursor;
      } while (cursor != null);
      expect(original, List.generate(125, (i) => 125 - i));
      expect(
        (await journal.recent()).map((e) => e['seq']),
        List.generate(20, (i) => 106 + i),
      );
      await journal.append(event(126));
      final stable = await journal.readPage(maxSequence: 125);
      expect(stable.events.first['seq'], 125);
      final bytes = <int>[];
      await for (final chunk in journal.csv()) {
        bytes.addAll(chunk);
      }
      final lines = const LineSplitter().convert(utf8.decode(bytes));
      expect(lines.length, 127);
      for (var i = 1; i <= 126; i++) {
        expect(decodeActionEvent(lines[i]), event(i));
      }
    },
  );

  test(
    'two writers retry exact events without duplicate or conflicting rows',
    () async {
      final name = ownedName();
      final first = await BrowserActionJournal.open(databaseName: name);
      final second = await BrowserActionJournal.open(databaseName: name);
      addTearDown(first.close);
      addTearDown(second.close);
      await Future.wait([first.append(event(1)), second.append(event(1))]);
      expect((await first.recent()).length, 1);
      await expectLater(
        second.append({...event(1), 'kind': 'different'}),
        throwsStateError,
      );
      await expectLater(second.append(event(3)), throwsStateError);
      await first.append(event(2));
      expect((await second.recent()).map((e) => e['seq']), [1, 2]);
    },
  );

  test('closing and reopening retains acknowledged records', () async {
    final name = ownedName();
    var journal = await BrowserActionJournal.open(databaseName: name);
    await journal.append(event(1));
    await journal.close();
    await expectLater(journal.append(event(2)), throwsStateError);
    journal = await BrowserActionJournal.open(databaseName: name);
    addTearDown(journal.close);
    expect(await journal.recent(), [event(1)]);
    await journal.append(event(2));
    expect(await journal.recent(), [event(1), event(2)]);
  });
  test(
    'Reset atomically deletes the target study and preserves paged CSV across reopen',
    () async {
      final name = ownedName();
      var journal = await BrowserActionJournal.open(databaseName: name);
      for (var i = 1; i <= 125; i++) {
        final row = event(i);
        (row['state'] as Map)['studyId'] = i.isEven ? 'erase' : 'keep';
        await journal.append(row);
      }
      final replacement = event(126)..['kind'] = 'reset';
      (replacement['state'] as Map)['studyId'] = 'fresh';
      (replacement['state'] as Map)['title'] = 'Pine';
      (replacement['state'] as Map)['cycle'] = 0;
      replacement['totalMs'] = 0;
      await journal.resetStudy('erase', replacement);
      await journal.close();
      journal = await BrowserActionJournal.open(databaseName: name);
      addTearDown(journal.close);
      final bytes = await journal.csv().expand((e) => e).toList();
      final rows = const LineSplitter()
          .convert(utf8.decode(bytes))
          .skip(1)
          .map(decodeActionEvent)
          .toList();
      expect(rows.length, 64);
      expect(rows.any((e) => (e['state'] as Map)['studyId'] == 'erase'), false);
      expect(rows.map((e) => e['seq']), List.generate(64, (i) => i + 1));
      expect(rows.last['state']['title'], 'Pine');
      await journal.append(event(65));
      final invalid = event(67);
      await expectLater(journal.resetStudy('keep', invalid), throwsStateError);
      expect((await journal.recent()).last['seq'], 65);
    },
  );
}
