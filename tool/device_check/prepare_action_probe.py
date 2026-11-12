"""Copy the current app into an isolated, debuggable Android QA package.

Only generated test data belongs in this app. Production identities and storage
are unchanged. Use a normal debug build, allowing run-as CSV reads. Changing
the release variant's debuggable flag can mix Flutter engine/snapshot modes.
"""
import hashlib
import json
from pathlib import Path
import shutil
import tempfile

def copy_ignore(directory, names):
    return set(names) & {'build', '.gradle', '.cxx', '.kotlin', '.dart_tool', '.symlinks', '.git', '__pycache__'}

def replace_once(text, before, after):
    if text.count(before) != 1:
        raise ValueError(f'Expected one source anchor: {before}')
    return text.replace(before, after, 1)

SOURCE = Path(__file__).resolve().parents[2]
PACKAGE = 'com.fieldstudy.field_tms.actionprobe'

def main():
    destination = Path(tempfile.mkdtemp(prefix='field-action-probe-')).resolve()
    assert destination.parent == Path(tempfile.gettempdir()).resolve()
    (destination / '.field-action-probe-owned').write_text('Generated activity capture QA only.\n')
    for name in ('pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml'):
        shutil.copy2(SOURCE / name, destination / name)
    for name in ('lib', 'android'):
        shutil.copytree(SOURCE / name, destination / name, ignore=copy_ignore)
    gradle = destination / 'android/app/build.gradle.kts'
    text = replace_once(gradle.read_text(), 'applicationId = "com.fieldstudy.field_tms"',
        f'applicationId = "{PACKAGE}"')
    gradle.write_text(text)
    manifest = destination / 'android/app/src/main/AndroidManifest.xml'
    text = replace_once(manifest.read_text(), 'android:label="Field Stopwatch"', 'android:label="Field Action QA"')
    for name in ('MainActivity', 'MotionRecordingService', 'LocationRecordingService'):
        text = replace_once(text, f'android:name=".{name}"', f'android:name="com.fieldstudy.field_tms.{name}"')
    manifest.write_text(text)
    hashes = {str(p.relative_to(SOURCE)).replace('\\', '/'): hashlib.sha256(p.read_bytes()).hexdigest()
        for directory in ('lib', 'android/app/src') for p in (SOURCE / directory).rglob('*') if p.is_file()}
    output = {'projectPath': str(destination), 'package': PACKAGE, 'entrypoint': 'lib/main.dart',
        'changes': ['Application ID', 'App label', 'Absolute component names'],
        'buildMode': 'Standard debug, for private CSV inspection',
        'productionSourceHashes': hashes}
    (SOURCE.parent / 'artifacts/action-probe-build.json').write_text(json.dumps(output, indent=2))
    print(json.dumps({'projectPath': str(destination), 'package': PACKAGE}))

if __name__ == '__main__': main()
