#!/usr/bin/env python3
"""Package local, source-only iOS validation inputs; never upload anything.

Build from the development checkout:
  python tool/device_check/package_ios_source.py
Verify the zip and its adjacent manifest:
  python tool/device_check/package_ios_source.py --verify
On a Mac, after extracting the zip, verify the source before running Flutter:
  python3 field_app/tool/device_check/package_ios_source.py --verify-tree .

The embedded manifest hashes every source member. The adjacent manifest also
hashes the completed zip; it is intentionally not embedded (no circular hash).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import tempfile
from datetime import datetime, timezone
import zipfile


APP = Path(__file__).resolve().parents[2]
WORKSPACE = APP.parent
ARTIFACTS = WORKSPACE / "artifacts"
ARCHIVE_NAME = "field-stopwatch-ios-source.zip"
BUNDLE_ROOT = "field-stopwatch-ios-source"
MAX_MEMBER_BYTES = 8 * 1024 * 1024
MAX_TOTAL_BYTES = 32 * 1024 * 1024
MAX_FILES = 1000
MAX_MANIFEST_BYTES = 2 * 1024 * 1024

EXCLUDED_PARTS = {
    ".git", ".dart_tool", ".idea", ".vscode", ".analysis", ".symlinks",
    ".gradle", "build", "Pods", "ephemeral", "DerivedData", "xcuserdata",
    "credentials", "research", "research_data", "raw_excel",
}
EXCLUDED_NAMES = {
    "Generated.xcconfig", "flutter_export_environment.sh", "local.properties",
    ".DS_Store", ".flutter-plugins-dependencies",
}
SECRET_SUFFIXES = {
    ".p8", ".p12", ".pfx", ".pem", ".key", ".keystore", ".jks",
    ".mobileprovision", ".cer", ".crt", ".xlsx", ".xls", ".csv",
}
IOS_SUFFIXES = {
    ".swift", ".h", ".m", ".plist", ".storyboard", ".xcconfig",
    ".pbxproj", ".xcscheme", ".xcsettings", ".xcworkspacedata", ".json",
    ".png", ".md", ".xcprivacy", ".entitlements",
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def linked(path: Path) -> bool:
    attributes = path.lstat()
    return path.is_symlink() or bool(
        getattr(attributes, "st_file_attributes", 0)
        & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0)
    )


def safe_relative(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if not value or path.is_absolute() or "\\" in value or ":" in value:
        raise ValueError(f"Unsafe member path: {value!r}")
    if any(part in (".", "..") for part in path.parts):
        raise ValueError(f"Unsafe member path: {value!r}")
    return path


def excluded(path: Path) -> bool:
    return (
        any(part in EXCLUDED_PARTS for part in path.parts)
        or path.name in EXCLUDED_NAMES
        or path.name.startswith("GeneratedPluginRegistrant.")
        or path.name.startswith(".env")
        or path.suffix.lower() in SECRET_SUFFIXES
    )


def source_tree(directory: Path, suffixes: set[str]) -> list[Path]:
    result: list[Path] = []
    if linked(directory):
        raise ValueError(f"Source directory is a link: {directory.name}")
    for current, directories, files in os.walk(directory, followlinks=False):
        base = Path(current)
        directories[:] = sorted(
            name for name in directories
            if not excluded(base / name) and not linked(base / name)
        )
        for name in sorted(files):
            path = base / name
            if excluded(path) or linked(path):
                continue
            if path.suffix.lower() in suffixes or name in {"Podfile", "Podfile.lock", ".gitignore"}:
                result.append(path)
    return result


def sources() -> list[Path]:
    required = [
        APP / "pubspec.yaml", APP / "pubspec.lock", APP / "analysis_options.yaml",
        APP / "README.md", APP / ".metadata",
        APP / "tool/device_check/validate_ios.sh",
        APP / "tool/device_check/README.md", Path(__file__),
        APP / "tool/fault_check/storage_full_scenarios.dart",
        WORKSPACE / "PRODUCT.md", WORKSPACE / "DESIGN.md", WORKSPACE / "IMPLEMENTATION.md",
    ]
    for path in required:
        if not path.is_file() or linked(path) or excluded(path):
            raise ValueError(f"Required source is unavailable or excluded: {path.name}")
    return sorted(set(
        required + source_tree(APP / "lib", {".dart"})
        + source_tree(APP / "test", {".dart"})
        + source_tree(APP / "ios", IOS_SUFFIXES)
    ), key=lambda path: path.relative_to(WORKSPACE).as_posix())


def capture(path: Path) -> bytes:
    resolved = path.resolve(strict=True)
    resolved.relative_to(WORKSPACE.resolve())
    if linked(path) or not path.is_file():
        raise ValueError(f"Source is not a regular file: {path.name}")
    before = path.stat()
    if before.st_size > MAX_MEMBER_BYTES:
        raise ValueError(f"Source is unexpectedly large: {path.name}")
    data = path.read_bytes()
    after = path.stat()
    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
        raise ValueError(f"Source changed while packaging; run again: {path.name}")
    return data


def encoded_manifest(manifest: dict) -> bytes:
    data = (json.dumps(manifest, ensure_ascii=True, indent=2, sort_keys=True) + "\n").encode("utf-8")
    if len(data) > MAX_MANIFEST_BYTES:
        raise ValueError("Manifest is unexpectedly large")
    return data


def zip_member(path: str, data: bytes) -> tuple[zipfile.ZipInfo, bytes]:
    safe_relative(path)
    entry = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
    entry.create_system = 3
    permissions = 0o755 if path.endswith((".sh", ".py")) else 0o644
    entry.external_attr = (stat.S_IFREG | permissions) << 16
    entry.compress_type = zipfile.ZIP_DEFLATED
    return entry, data


def build(flutter_tests: int) -> dict:
    snapshot: dict[str, bytes] = {}
    for source in sources():
        relative = source.relative_to(WORKSPACE).as_posix()
        safe_relative(relative)
        snapshot[relative] = capture(source)
    if len(snapshot) > MAX_FILES or sum(map(len, snapshot.values())) > MAX_TOTAL_BYTES:
        raise ValueError("Source package exceeds its bounded size limit")
    members = [
        {"path": path, "bytes": len(data), "sha256": sha256(data)}
        for path, data in sorted(snapshot.items())
    ]
    source_id = sha256("".join(
        f"{entry['path']}\0{entry['sha256']}\0{entry['bytes']}\n" for entry in members
    ).encode("utf-8"))
    native_tests = sum(
        len(re.findall(rb"\bfunc\s+test\w*\s*\(", data))
        for path, data in snapshot.items()
        if path.startswith("field_app/ios/RunnerTests/") and path.endswith(".swift")
    )
    manifest = {
        "formatVersion": 1,
        "archiveName": ARCHIVE_NAME,
        "bundleRoot": BUNDLE_ROOT,
        "createdAtUtc": datetime.now(timezone.utc).isoformat(),
        "sourceIdSha256": source_id,
        "sourceFileCount": len(members),
        "sourceBytes": sum(entry["bytes"] for entry in members),
        "validation": {
            "flutter": {
                "testsPassed": flutter_tests,
                "staticAnalysis": "clean",
                "evidence": "Prior task validation on the Windows host; packaging does not rerun Flutter checks.",
            },
            "ios": {
                "xctestMethodsWritten": native_tests,
                "swiftCompilation": "not_run",
                "xctestExecution": "not_run",
                "validationScript": "not_run_on_windows",
            },
        },
        "macInstructions": [
            "Extract the source zip; keep the adjacent manifest.json for archive identity.",
            "From the extracted bundle root: python3 field_app/tool/device_check/package_ios_source.py --verify-tree .",
            "Use Flutter 3.35.4 / Dart 3.9.2, Xcode, and CocoaPods; generated local configuration and plugins must be regenerated.",
            "List installed simulators with xcrun simctl list devices available and choose a verified destination.",
            "From field_app: bash tool/device_check/validate_ios.sh 'platform=iOS Simulator,id=<verified-UDID>'",
        ],
        "limitations": [
            "This is a local source handoff, not a compiled or signed iOS app, and nothing has been uploaded.",
            "Simulator results do not establish physical walking accuracy, full-day battery use, process-kill durability, power-loss behavior, or release readiness.",
            "Context documents may reference local device evidence and research examples that are intentionally not included.",
        ],
        "excluded": [
            "Build/cache/dependency directories, generated Flutter/Xcode configuration and registrants, local properties, IDE user state, symlinks and junctions.",
            "Credentials, signing keys/profiles, raw spreadsheets, research data, analysis data, and device evidence artifacts.",
        ],
        "members": members,
    }
    embedded = encoded_manifest(manifest)
    ARTIFACTS.mkdir(exist_ok=True)
    archive = ARTIFACTS / ARCHIVE_NAME
    descriptor, temporary_name = tempfile.mkstemp(prefix=".ios-source-", suffix=".zip", dir=ARTIFACTS)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as output:
            for path, data in sorted(snapshot.items()):
                entry, payload = zip_member(f"{BUNDLE_ROOT}/{path}", data)
                output.writestr(entry, payload)
            entry, payload = zip_member(f"{BUNDLE_ROOT}/manifest.json", embedded)
            output.writestr(entry, payload)
        os.replace(temporary, archive)
    finally:
        temporary.unlink(missing_ok=True)
    external = {
        **manifest,
        "archiveBytes": archive.stat().st_size,
        "archiveSha256": sha256(archive.read_bytes()),
        "embeddedManifestSha256": sha256(embedded),
    }
    (ARTIFACTS / "manifest.json").write_bytes(encoded_manifest(external))
    verify_archive()
    return external


def verify_archive() -> dict:
    archive = ARTIFACTS / ARCHIVE_NAME
    external = json.loads((ARTIFACTS / "manifest.json").read_bytes())
    if archive.stat().st_size != external["archiveBytes"] or sha256(archive.read_bytes()) != external["archiveSha256"]:
        raise ValueError("Archive size or SHA-256 differs from its manifest")
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        if len(entries) > MAX_FILES + 1 or sum(entry.file_size for entry in entries) > MAX_TOTAL_BYTES + MAX_MANIFEST_BYTES:
            raise ValueError("Archive exceeds the expected bounded source size")
        names = [entry.filename for entry in entries]
        if len(names) != len(set(names)):
            raise ValueError("Archive contains duplicate entries")
        for entry in entries:
            safe_relative(entry.filename)
            if stat.S_ISLNK(entry.external_attr >> 16) or entry.file_size > MAX_MEMBER_BYTES:
                raise ValueError("Archive contains a link or oversized member")
        embedded = source.read(f"{BUNDLE_ROOT}/manifest.json")
        if sha256(embedded) != external["embeddedManifestSha256"]:
            raise ValueError("Embedded manifest identity differs")
        internal = json.loads(embedded)
        base = {key: value for key, value in external.items() if key not in {
            "archiveBytes", "archiveSha256", "embeddedManifestSha256",
        }}
        if internal != base:
            raise ValueError("Embedded and adjacent source manifests differ")
        expected = {f"{BUNDLE_ROOT}/{entry['path']}" for entry in internal["members"]}
        expected.add(f"{BUNDLE_ROOT}/manifest.json")
        if set(names) != expected:
            raise ValueError("Archive members differ from the source manifest")
        for entry in internal["members"]:
            data = source.read(f"{BUNDLE_ROOT}/{entry['path']}")
            if len(data) != entry["bytes"] or sha256(data) != entry["sha256"]:
                raise ValueError(f"Source identity differs: {entry['path']}")
    return external


def verify_tree(root: Path) -> dict:
    root = root.resolve(strict=True)
    manifest_file = root / "manifest.json"
    if manifest_file.stat().st_size > MAX_MANIFEST_BYTES:
        raise ValueError("Manifest exceeds its size limit")
    manifest = json.loads(manifest_file.read_bytes())
    for entry in manifest["members"]:
        relative = safe_relative(entry["path"])
        path = root.joinpath(*relative.parts)
        path.resolve(strict=True).relative_to(root)
        if linked(path):
            raise ValueError(f"Extracted source is a link: {entry['path']}")
        if path.stat().st_size != entry["bytes"] or sha256(path.read_bytes()) != entry["sha256"]:
            raise ValueError(f"Extracted source differs: {entry['path']}")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    operation = parser.add_mutually_exclusive_group()
    operation.add_argument("--verify", action="store_true", help="Verify the local zip and adjacent manifest.")
    operation.add_argument("--verify-tree", type=Path, help="Verify an extracted bundle root against its embedded manifest.")
    parser.add_argument("--flutter-tests", type=int, default=140, help="Previously observed passing Flutter test count; does not run tests.")
    arguments = parser.parse_args()
    if arguments.flutter_tests <= 0:
        parser.error("--flutter-tests must be a positive previously observed count")
    if arguments.verify_tree is not None:
        manifest = verify_tree(arguments.verify_tree)
    elif arguments.verify:
        manifest = verify_archive()
    else:
        manifest = build(arguments.flutter_tests)
    print(json.dumps({key: manifest[key] for key in (
        "sourceFileCount", "sourceBytes", "sourceIdSha256", "validation",
    )}, indent=2))
    if "archiveSha256" in manifest:
        print(f"Archive SHA-256: {manifest['archiveSha256']}")


if __name__ == "__main__":
    main()
