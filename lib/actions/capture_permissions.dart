import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('field_tms/permissions');

/// Preparation never starts a study, microphone, or location service. Native
/// code remembers the first launch; capture paths only reuse existing grants.
Future<void> prepareCapturePermissions() async {
  if (kIsWeb) return;
  try {
    await _channel.invokeMethod<void>('prepare');
  } on MissingPluginException {
    /* Unsupported preview/test host. */
  } on PlatformException {
    /* Denied/unavailable access cannot block time capture. */
  }
}

Future<void> openCapturePermissionSettings() async {
  if (!kIsWeb) await _channel.invokeMethod<void>('openSettings');
}
