#!/usr/bin/env bash
# Run on a Mac with Xcode, CocoaPods and the pinned Flutter SDK available.
# Pass an existing simulator destination to run the native XCTest target too:
# ./tool/device_check/validate_ios.sh 'platform=iOS Simulator,id=<UDID>'
set -euo pipefail
cd "$(dirname "$0")/../.."
for command_name in flutter xcodebuild xcrun pod plutil; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required tool is missing: $command_name" >&2
    exit 2
  fi
done
result_directory="$(pwd)/../artifacts/ios-validation-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$result_directory"
flutter --version > "$result_directory/flutter-version.txt"
if ! grep -Fq 'Flutter 3.35.4 ' "$result_directory/flutter-version.txt" ||
   ! grep -Fq 'Dart 3.9.2 ' "$result_directory/flutter-version.txt"; then
  echo "Use Flutter 3.35.4 / Dart 3.9.2 for this validation. Clock behavior was reviewed for that SDK." >&2
  exit 2
fi
xcodebuild -version > "$result_directory/xcode-version.txt"
flutter pub get
flutter analyze 2>&1 | tee "$result_directory/analysis.txt"
flutter test 2>&1 | tee "$result_directory/flutter-tests.txt"
plutil -lint ios/Runner/PrivacyInfo.xcprivacy 2>&1 | tee "$result_directory/privacy-source.txt"
flutter build ios --simulator --debug --no-codesign 2>&1 | tee "$result_directory/ios-build.txt"
bundled_privacy="build/ios/iphonesimulator/Runner.app/PrivacyInfo.xcprivacy"
if [[ ! -f "$bundled_privacy" ]]; then
  echo "The built iOS app is missing its privacy manifest." >&2
  exit 4
fi
plutil -lint "$bundled_privacy" 2>&1 | tee "$result_directory/privacy-bundle.txt"
if [[ $# -eq 0 ]]; then
  echo "Simulator build passed. XCTest has NOT run."
  echo "List installed simulators with: xcrun simctl list devices available"
  echo "Run again with an exact simulator destination to execute XCTest."
  exit 3
fi
xcodebuild test -workspace ios/Runner.xcworkspace -scheme Runner \
  -destination "$1" -resultBundlePath "$result_directory/RunnerTests.xcresult" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$result_directory/native-tests.txt"
echo "Build and test commands passed. Results: $result_directory"
echo "Physical walking, screen lock, process death and power-loss behavior still require device validation."
