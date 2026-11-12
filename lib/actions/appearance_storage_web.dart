import 'package:web/web.dart' as web;

Future<bool?> readDark() async {
  try {
    return switch (web.window.localStorage.getItem('field-tms-dark')) {
      'true' => true,
      'false' => false,
      _ => null,
    };
  } catch (_) {
    return null;
  }
}

Future<void> writeDark(bool value) async {
  web.window.localStorage.setItem('field-tms-dark', '$value');
}
