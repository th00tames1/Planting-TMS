import 'package:flutter/services.dart';

const _channel = MethodChannel('field_tms/preferences');
Future<bool?> readDark() async {
  try {
    return await _channel.invokeMethod<bool>('readDark');
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

Future<void> writeDark(bool value) async {
  try {
    await _channel.invokeMethod<void>('writeDark', {'dark': value});
  } on MissingPluginException {
    /* Unit-test host. */
  }
}
