import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'action_recorder.dart';
import 'appearance.dart';
import 'capture_permissions.dart';

const updateRepository = 'th00tames1/Planting-TMS';

class AppUpdates {
  static const channel = MethodChannel('field_tms/updates');
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (!supported) return {'supported': false};
    try {
      return await channel.invokeMapMethod<String, dynamic>(method, {
            'repository': updateRepository,
            ...args,
          }) ??
          {};
    } on MissingPluginException {
      return {'supported': false};
    }
  }

  Future<void> autoCheck() async {
    try {
      await call('check', {'force': false});
    } catch (_) {
      /* Offline capture never waits for updates. */
    }
  }
}

class AppSettings extends StatefulWidget {
  const AppSettings({super.key, required this.recorder});
  final ActionRecorder recorder;
  @override
  State<AppSettings> createState() => _AppSettingsState();
}

class _AppSettingsState extends State<AppSettings> {
  final _updates = AppUpdates();
  Map<String, dynamic>? _state;
  String? _message;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _run('settings');
  }

  Future<void> _run(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final state = await _updates.call(method, args);
      if (mounted) {
        setState(() {
          _state = state;
          _message = state['message'] as String?;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'Could not reach the update service. Try again when connected.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state ?? {};
    final available = state['available'] == true;
    final stopped =
        !widget.recorder.running &&
        widget.recorder.pending == 0 &&
        widget.recorder.error == null;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Planting TMS',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              state['versionName'] == null
                  ? 'Field time and motion studies'
                  : 'Version ${state['versionName']} · ${state['versionCode']}',
            ),
            const SizedBox(height: 28),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Dark screen'),
              subtitle: const Text(
                'Lower screen power on OLED displays. Choose the most readable setting outdoors.',
              ),
              value: Theme.of(context).brightness == Brightness.dark,
              onChanged: (dark) => Appearance.setDark(dark),
            ),
            const SizedBox(height: 16),
            if (!kIsWeb) ...[
              OutlinedButton.icon(
                onPressed: !_busy && stopped
                    ? () async {
                        try {
                          await openCapturePermissionSettings();
                        } catch (_) {
                          if (mounted) {
                            setState(
                              () => _message =
                                  'Open app permissions in your phone settings.',
                            );
                          }
                        }
                      }
                    : null,
                icon: const Icon(Icons.privacy_tip_outlined, size: 18),
                label: const Text('App permissions'),
              ),
              const SizedBox(height: 16),
            ],
            if (_updates.supported && state['supported'] != false) ...[
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Automatically check for updates'),
                subtitle: const Text(
                  'Checks GitHub once a day when the study is stopped. No continuous background checks.',
                ),
                value: state['automatic'] == true,
                onChanged: _busy
                    ? null
                    : (value) => _run('automatic', {'enabled': value}),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: !_busy ? () => _run('check', {'force': true}) : null,
                child: const Text('Check for updates'),
              ),
              if (available) ...[
                const SizedBox(height: 20),
                Text(
                  'Version ${state['latestVersion']} is available.',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: !_busy && stopped ? () => _run('install') : null,
                  child: Text(
                    _busy
                        ? 'Downloading and verifying…'
                        : 'Download and install',
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Stop timing before installing. Android will ask you to approve the update. Your saved study stays on this device.',
                ),
              ],
            ] else
              const Text(
                'In-app APK updates are available on Android. iPhone updates use TestFlight or the App Store.',
              ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 20),
                child: LinearProgressIndicator(),
              ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Text(_message!),
              ),
          ],
        ),
      ),
    );
  }
}
