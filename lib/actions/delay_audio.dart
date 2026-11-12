import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native encoders stream compressed audio directly to private files. No PCM
/// samples, waveforms or periodic polling cross the Flutter bridge.
class DelayAudio {
  static const channel = MethodChannel('field_tms/delay_audio');
  Stream<Map<String, dynamic>> get events => kIsWeb
      ? const Stream.empty()
      : const EventChannel('field_tms/delay_audio_events')
            .receiveBroadcastStream()
            .map((value) => Map<String, dynamic>.from(value as Map));
  Future<Map<String, dynamic>?> setTarget(String? file) async {
    if (kIsWeb) {
      return file == null ? null : {'file': file, 'status': 'unavailable'};
    }
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'setTarget',
        {'file': file},
      );
      return result == null ? null : Map<String, dynamic>.from(result);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      return {'file': file, 'status': 'error', 'message': error.message};
    }
  }

  Future<void> deleteStudy(String studyId) async {
    if (!kIsWeb) {
      await channel.invokeMethod<void>('deleteStudy', {'studyId': studyId});
    }
  }

  Future<void> play(String file) async {
    if (kIsWeb) {
      throw StateError('Audio notes are available in the mobile app.');
    }
    await channel.invokeMethod<void>('play', {'file': file});
  }

  Future<void> stopPlayback() async {
    if (!kIsWeb) {
      try {
        await channel.invokeMethod<void>('stopPlayback');
      } on MissingPluginException {
        /* Unit-test host. */
      }
    }
  }
}
