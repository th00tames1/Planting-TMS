import 'action_journal.dart';
import 'open_action_journal_native.dart'
    if (dart.library.js_interop) 'action_journal_web.dart'
    as platform;

Future<ActionJournal> openActionJournal() => platform.openActionJournal();
