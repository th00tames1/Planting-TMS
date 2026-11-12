import 'dart:convert';
import 'dart:io';
import 'package:field_tms/actions/action_journal_native.dart';

/// An external process kills this writer after acknowledged fsyncs. Generated
/// data only. The verifier reopens the same production CSV journal class.
Future<void> main(List<String> args) async {
  final journal = await FileActionJournal.open(File(args[1]));
  final recent = await journal.recent();
  if (args[0] == 'verify') {
    stdout.writeln(
      jsonEncode({
        'sequence': recent.lastOrNull?['seq'] ?? 0,
        'repairedBytes': journal.repairedBytes,
        'latestCount': recent.length,
      }),
    );
    await journal.close();
    return;
  }
  var sequence = recent.lastOrNull?['seq'] as int? ?? 0;
  while (true) {
    sequence++;
    final boundary = {
      'utc': DateTime.now().toUtc().toIso8601String(),
      'monoMs': sequence * 7,
      'location': {'status': 'unavailable'},
    };
    await journal.append({
      'seq': sequence,
      'kind': 'action',
      'boundary': boundary,
      'closed': null,
      'totalMs': sequence * 7,
      'state': {
        'studyId': 'generated-crash-probe',
        'seq': sequence,
        'running': true,
        'action': sequence.isOdd ? 'Walking' : 'Planting',
        'active': boundary,
      },
    });
    stdout.writeln(sequence);
    await stdout.flush();
  }
}
