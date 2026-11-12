# Planting TMS

A simple Flutter stopwatch for field time and motion studies on Android and iOS.

- Dark mode by default, with a Light option in Settings.
- Large digital timer, one-screen capture and buttons within one-handed reach.
- Planting starts a Cycle; Walking, Preparation and Walk out retain their study rules.
- Overlapping Delay with Personal, Operational, Mechanical and Administrative reasons.
- Compressed spoken notes during Delay, with a small playback button beside each saved Delay.
- Saved records grouped by Study, with a vertical Cycle/activity/decimal-minute timetable.
- Observer walking estimates from native motion sensors and automatic GPS capture when permitted.
- Every accepted activity boundary is saved locally. Extract CSV creates a copy with milliseconds and decimal minutes.
- Editable study titles. Reset deletes only the current study after confirmation; New study keeps earlier projects.

## Install

Download the Android ARM64 APK from [Releases](https://github.com/th00tames1/Planting-TMS/releases). Settings can check for new releases and download a verified update; Android asks for installation approval. Automatic checks are off by default. If enabled, they run at most daily while timing is stopped. Updates never require a GitHub token in the app.

iOS source is included. Building requires macOS/Xcode; distribution and updates use TestFlight or the App Store. The browser preview does not record microphone or native walking data.

See [PERFORMANCE.md](PERFORMANCE.md) for the resource audit and remaining device qualification.

## Develop

```sh
flutter pub get
flutter test
flutter run
```

The UI is English. The capture screen does not scroll. Microphone, GPS, motion and Android notification permissions are prepared at first launch. Measurement and Delay taps never open permission prompts; access can be changed through Settings > App permissions. Native CSV writes are flushed at each boundary. Same-boot clock recovery preserves timing; unknown intervals after reboot require review. Voice notes can be interrupted by the OS, and a note open during process termination may be incomplete. Full-day battery, sensor accuracy, device recording and iOS execution still need field qualification.

## Publish an Android update

Build with a larger Android version code and the same signing key as the installed pilot app. Never commit signing keys or tokens. The current pilot build uses the local Android debug signing key, so another computer cannot produce an installable update without the same key.

```sh
flutter build apk --release --target-platform android-arm64 --build-number 202611125 --build-name 1.2.1
```

Publish the APK and `update.json` together in a stable GitHub Release. The manifest contains `packageId`, `versionCode`, `versionName`, `apkFile`, `byteCount` and `sha256`. The updater validates file size, SHA-256, package ID, version and signing certificate before opening the Android installer. Keep releases immutable; publish a new version instead of replacing an APK.
