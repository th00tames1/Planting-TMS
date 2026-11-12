import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'action_journal.dart';
import 'versioned_action_journal.dart';

Future<ActionJournal> openActionJournal() async =>
    openVersionedActionJournal(Directory(await getDatabasesPath()));
