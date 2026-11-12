import 'package:flutter/material.dart';
import 'appearance_storage_native.dart'
    if (dart.library.js_interop) 'appearance_storage_web.dart'
    as storage;

class Appearance {
  static final mode = ValueNotifier<ThemeMode>(ThemeMode.dark);
  static int _revision = 0;
  static Future<void> load() async {
    final revision = _revision;
    final value = await storage.readDark();
    if (revision != _revision) return;
    mode.value = value == null
        ? ThemeMode.dark
        : value
        ? ThemeMode.dark
        : ThemeMode.light;
  }

  static Future<void> setDark(bool dark) async {
    _revision++;
    mode.value = dark ? ThemeMode.dark : ThemeMode.light;
    await storage.writeDark(dark);
  }
}
