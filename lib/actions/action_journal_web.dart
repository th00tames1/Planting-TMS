import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;
import 'action_journal.dart';
import 'coordinated_action_journal.dart';

Future<ActionJournal> openActionJournal() async =>
    CoordinatedActionJournal(await BrowserActionJournal.open());
typedef _Abort = void Function(Object, StackTrace);

/// Activity events only, retaining the existing database, keys and payloads.
class BrowserActionJournal
    implements PagedActionJournal, ResettableActionJournal {
  BrowserActionJournal._(this._database) {
    _database.onversionchange = ((web.Event _) {
      _closed = true;
      _database.close();
    }).toJS;
  }
  final web.IDBDatabase _database;
  bool _closed = false;
  // Historical storage key, not an entry into the removed stopwatch workflow.
  static const _namespace = 'legacy-v1';
  static const _snapshots = 'session_snapshots';
  static const _recordsStore = 'session_records';

  static Future<BrowserActionJournal> open({
    String databaseName = 'field_tms_actions_v1',
  }) async {
    final ready = Completer<BrowserActionJournal>();
    final request = web.window.indexedDB.open(databaseName, 2);
    request.onupgradeneeded = ((web.Event _) {
      final database = request.result as web.IDBDatabase;
      for (final name in [_snapshots, _recordsStore]) {
        if (!database.objectStoreNames.contains(name)) {
          database.createObjectStore(name);
        }
      }
    }).toJS;
    request.onsuccess = ((web.Event _) {
      final database = request.result as web.IDBDatabase;
      if (ready.isCompleted) {
        database.close();
      } else {
        ready.complete(BrowserActionJournal._(database));
      }
    }).toJS;
    request.onerror = ((web.Event _) {
      if (!ready.isCompleted) {
        ready.completeError(
          StateError('Could not open saved activity records.'),
        );
      }
    }).toJS;
    request.onblocked = ((web.Event _) {
      if (!ready.isCompleted) {
        ready.completeError(
          StateError('Close another preview before updating storage.'),
        );
      }
    }).toJS;
    return ready.future;
  }

  @override
  String get description => 'Browser preview · saved on this browser';
  static Map<String, dynamic>? _decode(JSAny? value) => value.isUndefinedOrNull
      ? null
      : Map<String, dynamic>.from(
          jsonDecode((value as JSString).toDart) as Map,
        );

  Future<Map<String, dynamic>?> _load() =>
      _transaction('readonly', (tx, output, abort) {
        _onSuccess(
          tx.objectStore(_snapshots).get(_namespace.toJS),
          abort,
          (value) => output(_decode(value)),
        );
      });

  Future<List<Map<String, dynamic>>> _records({
    required int limit,
    required int maxSequence,
    int afterSequence = 0,
    int? beforeSequence,
    String direction = 'prev',
  }) => _transaction('readonly', (tx, output, abort) {
    final rows = <Map<String, dynamic>>[];
    output(rows);
    final range = web.IDBKeyRange.bound(
      [_namespace, afterSequence + 1].jsify(),
      [
        _namespace,
        beforeSequence == null || beforeSequence > maxSequence
            ? maxSequence
            : beforeSequence - 1,
      ].jsify(),
    );
    final request = tx.objectStore(_recordsStore).openCursor(range, direction);
    _onSuccess(request, abort, (value) {
      if (value.isUndefinedOrNull) return;
      final cursor = value as web.IDBCursorWithValue;
      rows.add(_decode(cursor.value)!);
      if (rows.length < limit) cursor.continue_();
    });
  });

  @override
  Future<List<Map<String, dynamic>>> recent() async => (await _records(
    limit: 20,
    maxSequence: 9007199254740991,
  )).reversed.toList();

  @override
  Future<ActionJournalPage> readPage({
    String? cursor,
    int limit = 50,
    required int maxSequence,
  }) async {
    validateActionPage(limit, maxSequence);
    final before = cursor == null ? null : int.parse(cursor);
    if (before != null && before <= 0) {
      throw const FormatException('Invalid saved-record cursor.');
    }
    if (maxSequence == 0 || before == 1) return const ActionJournalPage([]);
    final rows = await _records(
      limit: limit + 1,
      beforeSequence: before,
      maxSequence: maxSequence,
    );
    final hasOlder = rows.length > limit;
    if (hasOlder) rows.removeLast();
    return ActionJournalPage(
      rows,
      nextCursor: hasOlder ? '${rows.last['seq']}' : null,
    );
  }

  @override
  Future<void> append(Map<String, dynamic> event) {
    // Snapshot and event commit atomically. Retries keep their original payload.
    final encoded = jsonEncode(event);
    final frozen = jsonDecode(encoded) as Map;
    final sequence = frozen['seq'] as int;
    return _transaction<void>('readwrite', (tx, output, abort) {
      _onSuccess(tx.objectStore(_snapshots).get(_namespace.toJS), abort, (
        value,
      ) {
        final previous = _decode(value);
        final previousSequence = previous?['seq'] as int? ?? 0;
        if (previousSequence == sequence) {
          if (jsonEncode(previous?['event']) != encoded) {
            throw StateError('Journal event sequence conflict.');
          }
          return;
        }
        if (sequence != previousSequence + 1) {
          throw StateError('Journal event sequence is incomplete.');
        }
        tx
            .objectStore(_recordsStore)
            .add(encoded.toJS, [_namespace, sequence].jsify());
        tx
            .objectStore(_snapshots)
            .put(
              jsonEncode({
                'seq': sequence,
                'event': frozen,
                'phase': (frozen['state'] as Map)['running'] == true
                    ? 'running'
                    : 'paused',
                'completedCount': sequence,
                'elapsedMs': frozen['totalMs'],
              }).toJS,
              _namespace.toJS,
            );
      });
    });
  }

  @override
  Future<void> resetStudy(
    String studyId,
    Map<String, dynamic> replacement,
  ) => _transaction<void>('readwrite', (tx, output, abort) {
    final records = tx.objectStore(_recordsStore);
    final snapshots = tx.objectStore(_snapshots);
    _onSuccess(snapshots.get(_namespace.toJS), abort, (value) {
      final previous = _decode(value);
      if ((previous?['seq'] as int? ?? 0) + 1 != replacement['seq']) {
        throw StateError('Study changed before Reset.');
      }
      var sequence = 0;
      final range = web.IDBKeyRange.bound(
        [_namespace, 0].jsify(),
        [_namespace, 9007199254740991].jsify(),
      );
      final request = records.openCursor(range, 'next');
      _onSuccess(request, abort, (value) {
        if (value.isUndefinedOrNull) {
          final event = Map<String, dynamic>.from(
            jsonDecode(jsonEncode(replacement)) as Map,
          );
          event['seq'] = ++sequence;
          (event['state'] as Map)['seq'] = sequence;
          records.put(jsonEncode(event).toJS, [_namespace, sequence].jsify());
          snapshots.put(
            jsonEncode({
              'seq': sequence,
              'event': event,
              'phase': 'paused',
              'completedCount': sequence,
              'elapsedMs': 0,
            }).toJS,
            _namespace.toJS,
          );
          return;
        }
        final cursor = value as web.IDBCursorWithValue;
        final event = _decode(cursor.value)!;
        final oldSequence = event['seq'];
        if ((event['state'] as Map)['studyId'] == studyId) {
          cursor.delete();
        } else {
          event['seq'] = ++sequence;
          (event['state'] as Map)['seq'] = sequence;
          if (oldSequence != sequence) cursor.delete();
          records.put(jsonEncode(event).toJS, [_namespace, sequence].jsify());
        }
        cursor.continue_();
      });
    });
  });

  @override
  Stream<Uint8List> csv() async* {
    yield Uint8List.fromList(utf8.encode(actionCsvHeader));
    final count = (await _load())?['seq'] as int? ?? 0;
    var after = 0;
    while (after < count) {
      final rows = await _records(
        limit: 100,
        afterSequence: after,
        direction: 'next',
        maxSequence: count,
      );
      if (rows.isEmpty) throw StateError('Saved records ended unexpectedly.');
      for (final event in rows) {
        yield Uint8List.fromList(utf8.encode(encodeActionEvent(event)));
      }
      after = rows.last['seq'] as int;
    }
  }

  Future<T> _transaction<T>(
    String mode,
    void Function(web.IDBTransaction, void Function(T), _Abort) work,
  ) async {
    if (_closed) throw StateError('Activity storage is closed.');
    final names = [_snapshots.toJS, _recordsStore.toJS].toJS;
    final tx = mode == 'readwrite'
        ? _database.transaction(
            names,
            mode,
            web.IDBTransactionOptions(durability: 'strict'),
          )
        : _database.transaction(names, mode);
    final completion = Completer<T>();
    T? value;
    Object? failure;
    StackTrace? trace;
    void finishError() {
      if (!completion.isCompleted) {
        completion.completeError(
          failure ??
              StateError(
                'Activity storage transaction failed: ${tx.error?.message}',
              ),
          trace ?? StackTrace.current,
        );
      }
    }

    void abort(Object error, StackTrace stack) {
      failure = error;
      trace = stack;
      try {
        tx.abort();
      } catch (_) {
        finishError();
      }
    }

    tx.oncomplete = ((web.Event _) {
      if (failure != null) {
        finishError();
      } else if (!completion.isCompleted) {
        completion.complete(value);
      }
    }).toJS;
    tx.onabort = ((web.Event _) => finishError()).toJS;
    tx.onerror = ((web.Event _) {
      failure ??= StateError(
        'Activity storage transaction failed: ${tx.error?.message}',
      );
    }).toJS;
    try {
      work(tx, (result) => value = result, abort);
    } catch (error, stack) {
      abort(error, stack);
    }
    return completion.future;
  }

  static void _onSuccess(
    web.IDBRequest request,
    _Abort abort,
    void Function(JSAny?) action,
  ) {
    request.onsuccess = ((web.Event _) {
      try {
        action(request.result);
      } catch (error, stack) {
        abort(error, stack);
      }
    }).toJS;
  }

  @override
  Future<void> close() async {
    _closed = true;
    _database.close();
  }
}
