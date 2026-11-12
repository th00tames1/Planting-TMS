import 'dart:async';
import 'dart:typed_data';
import 'action_journal.dart';

/// Short history reads and automatic audio-result writes share the same gate.
/// A sensor/audio callback during browsing waits instead of failing a save.
class CoordinatedActionJournal
    implements PagedActionJournal, ResettableActionJournal {
  CoordinatedActionJournal(this.source);
  final ActionJournal source;
  Future<void> _tail = Future.value();
  Future<T> _run<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  @override
  String get description => source.description;
  @override
  Future<List<Map<String, dynamic>>> recent() => _run(source.recent);
  @override
  Future<void> append(Map<String, dynamic> event) =>
      _run(() => source.append(event));
  @override
  Future<ActionJournalPage> readPage({
    String? cursor,
    int limit = 50,
    required int maxSequence,
  }) => _run(
    () => readActionPage(
      source,
      cursor: cursor,
      limit: limit,
      maxSequence: maxSequence,
    ),
  );
  @override
  Future<void> resetStudy(String studyId, Map<String, dynamic> replacement) =>
      _run(() {
        final journal = source;
        if (journal is! ResettableActionJournal) {
          throw StateError('This journal cannot be reset.');
        }
        return journal.resetStudy(studyId, replacement);
      });
  @override
  Stream<Uint8List> csv() async* {
    final ready = Completer<void>();
    final release = Completer<void>();
    final held = _run(() async {
      ready.complete();
      await release.future;
    });
    await ready.future;
    try {
      yield* source.csv();
    } finally {
      release.complete();
      await held;
    }
  }

  @override
  Future<void> close() => _run(source.close);
}
