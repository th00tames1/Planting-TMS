import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'action_journal.dart';
import 'versioned_action_journal.dart';
import 'coordinated_action_journal.dart';

Future<ActionJournal> openActionJournal() async => CoordinatedActionJournal(
  await openVersionedActionJournal(Directory(await getDatabasesPath())),
);
