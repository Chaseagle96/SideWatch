#!/usr/bin/env python3
"""Validate the install-critical structure of a Watch-capable IPA.

This intentionally validates the ZIP/package boundary rather than trying to
replace Apple's code-signature verifier. On macOS, pass --verify-codesign to
also run `codesign --verify --deep --strict` against the extracted app.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Any


WATCH_PLATFORM = "watchos"
WATCH_EXTENSION_POINT = "com.apple.watchkit"
MACHO_MAGICS = {
    b"\xce\xfa\xed\xfe",  # 32-bit little endian
    b"\xfe\xed\xfa\xce",  # 32-bit big endian
    b"\xcf\xfa\xed\xfe",  # 64-bit little endian
    b"\xfe\xed\xfa\xcf",  # 64-bit big endian
    b"\xca\xfe\xba\xbe",  # fat/universal big endian
    b"\xbe\xba\xfe\xca",  # fat/universal little endian
}


class Report:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.facts: dict[str, Any] = {}

    def error(self, message: str) -> None:
        self.errors.append(message)

    def warning(self, message: str) -> None:
        self.warnings.append(message)


def read_plist(path: Path, report: Report, label: str) -> dict[str, Any] | None:
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as exc:
        report.error(f"{label}: cannot read Info.plist ({exc})")
        return None
    if not isinstance(value, dict):
        report.error(f"{label}: Info.plist is not a dictionary")
        return None
    return value


def string_value(info: dict[str, Any], key: str) -> str | None:
    value = info.get(key)
    return value if isinstance(value, str) else None


def platform_names(info: dict[str, Any]) -> set[str]:
    values = info.get("CFBundleSupportedPlatforms", [])
    if isinstance(values, str):
        values = [values]
    if not isinstance(values, list):
        values = []
    return {value.casefold() for value in values if isinstance(value, str)}


def is_watch_info(info: dict[str, Any]) -> bool:
    if WATCH_PLATFORM in platform_names(info):
        return True
    platform = string_value(info, "DTPlatformName")
    return platform is not None and platform.casefold() == WATCH_PLATFORM


def is_directory(path: Path) -> bool:
    return path.is_dir() and not path.is_symlink()


def check_binary(
    bundle: Path,
    info: dict[str, Any],
    report: Report,
    label: str,
    allow_inferred_watch_executable: bool = False,
) -> None:
    executable = string_value(info, "CFBundleExecutable")
    if not executable:
        if not allow_inferred_watch_executable:
            report.error(f"{label}: CFBundleExecutable is missing")
            return
        candidates = []
        for candidate in bundle.iterdir():
            if not candidate.is_file() or candidate.name in {"Info.plist", "PkgInfo"}:
                continue
            try:
                if candidate.read_bytes()[:4] in MACHO_MAGICS:
                    candidates.append(candidate)
            except OSError:
                continue
        if len(candidates) != 1:
            report.error(
                f"{label}: CFBundleExecutable is missing and exactly one direct Mach-O could not be inferred"
            )
            return
        executable_path = candidates[0]
    else:
        executable_path = bundle / executable
    if not executable_path.is_file():
        report.error(f"{label}: executable is missing: {executable_path.name}")
        return
    try:
        magic = executable_path.read_bytes()[:4]
    except OSError as exc:
        report.error(f"{label}: executable cannot be read ({exc})")
        return
    if magic not in MACHO_MAGICS:
        report.error(f"{label}: executable is not a recognized Mach-O binary")


def check_signature_material(
    bundle: Path, report: Report, label: str, require_signature: bool
) -> None:
    profile = bundle / "embedded.mobileprovision"
    code_resources = bundle / "_CodeSignature" / "CodeResources"
    if not profile.is_file():
        message = f"{label}: embedded.mobileprovision is missing"
        (report.error if require_signature else report.warning)(message)
    if not code_resources.is_file():
        message = f"{label}: _CodeSignature/CodeResources is missing"
        (report.error if require_signature else report.warning)(message)


def check_watch_extension(
    extension: Path,
    watch_app_id: str,
    root_app_id: str,
    report: Report,
    require_signature: bool,
) -> None:
    label = f"WatchKit extension {extension.name}"
    info_path = extension / "Info.plist"
    info = read_plist(info_path, report, label)
    if info is None:
        return

    extension_id = string_value(info, "CFBundleIdentifier")
    if not extension_id:
        report.error(f"{label}: CFBundleIdentifier is missing")
    if not is_watch_info(info):
        report.error(f"{label}: platform metadata is not watchOS")
    if info.get("UIDeviceFamily") and 4 not in info.get("UIDeviceFamily", []):
        report.error(f"{label}: UIDeviceFamily does not include Apple Watch (4)")

    extension_info = info.get("NSExtension")
    if not isinstance(extension_info, dict):
        report.error(f"{label}: NSExtension dictionary is missing")
    else:
        point = extension_info.get("NSExtensionPointIdentifier")
        if point != WATCH_EXTENSION_POINT:
            report.error(
                f"{label}: NSExtensionPointIdentifier is {point!r}, expected {WATCH_EXTENSION_POINT!r}"
            )
        attributes = extension_info.get("NSExtensionAttributes")
        if not isinstance(attributes, dict):
            report.error(f"{label}: NSExtensionAttributes dictionary is missing")
        else:
            declared_watch_id = attributes.get("WKAppBundleIdentifier")
            if declared_watch_id != watch_app_id:
                report.error(
                    f"{label}: WKAppBundleIdentifier {declared_watch_id!r} does not match Watch app {watch_app_id!r}"
                )

    check_binary(extension, info, report, label)
    check_signature_material(extension, report, label, require_signature)


def check_watch_app(
    watch_app: Path,
    root_app_id: str,
    report: Report,
    require_signature: bool,
) -> None:
    label = f"Watch app {watch_app.name}"
    info = read_plist(watch_app / "Info.plist", report, label)
    if info is None:
        return

    watch_app_id = string_value(info, "CFBundleIdentifier")
    if not watch_app_id:
        report.error(f"{label}: CFBundleIdentifier is missing")
        watch_app_id = "<missing>"
    if not is_watch_info(info):
        report.error(f"{label}: platform metadata is not watchOS")
    if 4 not in info.get("UIDeviceFamily", []):
        report.error(f"{label}: UIDeviceFamily does not include Apple Watch (4)")
    if info.get("WKApplication") is not True:
        report.error(f"{label}: WKApplication is not true")

    companion_id = string_value(info, "WKCompanionAppBundleIdentifier")
    if companion_id != root_app_id:
        report.error(
            f"{label}: WKCompanionAppBundleIdentifier {companion_id!r} does not match iOS app {root_app_id!r}"
        )

    check_binary(watch_app, info, report, label, allow_inferred_watch_executable=True)
    check_signature_material(watch_app, report, label, require_signature)

    plug_ins = watch_app / "PlugIns"
    extensions = sorted(
        (path for path in plug_ins.iterdir() if path.suffix.casefold() == ".appex")
        if is_directory(plug_ins)
        else [],
        key=lambda path: path.name,
    )
    if not extensions:
        report.error(f"{label}: no nested WatchKit extension was found in PlugIns/")
    for extension in extensions:
        check_watch_extension(
            extension,
            watch_app_id,
            root_app_id,
            report,
            require_signature,
        )


def validate_zip(ipa: Path, report: Report, require_signature: bool) -> Path | None:
    if not ipa.is_file():
        report.error(f"IPA does not exist: {ipa}")
        return None

    try:
        archive = zipfile.ZipFile(ipa)
    except (OSError, zipfile.BadZipFile) as exc:
        report.error(f"IPA is not a readable ZIP archive: {exc}")
        return None

    try:
        names = archive.namelist()
        for name in names:
            path = Path(name)
            if path.is_absolute() or ".." in path.parts:
                report.error(f"IPA contains an unsafe ZIP path: {name}")
            info = archive.getinfo(name)
            mode = (info.external_attr >> 16) & 0o170000
            if mode == 0o120000:
                report.error(f"IPA contains a symlink, which is not install-safe: {name}")
    finally:
        archive.close()

    if report.errors:
        return None

    extraction_root = Path(tempfile.mkdtemp(prefix="watch-ipa-"))
    report.facts["extraction_root"] = str(extraction_root)
    try:
        with zipfile.ZipFile(ipa) as archive:
            archive.extractall(extraction_root)
    except (OSError, zipfile.BadZipFile) as exc:
        report.error(f"IPA extraction failed: {exc}")
        shutil.rmtree(extraction_root, ignore_errors=True)
        return None

    payload = extraction_root / "Payload"
    if not is_directory(payload):
        report.error("IPA is missing Payload/")
        return extraction_root

    root_apps = sorted(
        (path for path in payload.iterdir() if path.suffix.casefold() == ".app" and is_directory(path)),
        key=lambda path: path.name,
    )
    if len(root_apps) != 1:
        report.error(f"Payload must contain exactly one root .app; found {len(root_apps)}")
        return extraction_root

    root_app = root_apps[0]
    root_info = read_plist(root_app / "Info.plist", report, f"Root app {root_app.name}")
    if root_info is None:
        return extraction_root

    root_id = string_value(root_info, "CFBundleIdentifier")
    if not root_id:
        report.error("Root app: CFBundleIdentifier is missing")
        root_id = "<missing>"
    if "iphoneos" not in platform_names(root_info):
        report.error("Root app: CFBundleSupportedPlatforms does not include iPhoneOS")
    check_binary(root_app, root_info, report, f"Root app {root_app.name}")
    check_signature_material(root_app, report, f"Root app {root_app.name}", require_signature)

    watch_directories = [root_app / "Watch", root_app / "WatchKit"]
    watch_apps = sorted(
        (
            child
            for directory in watch_directories
            if is_directory(directory)
            for child in directory.iterdir()
            if child.suffix.casefold() == ".app" and is_directory(child)
        ),
        key=lambda path: path.as_posix(),
    )
    report.facts.update(
        {
            "root_app": root_app.name,
            "root_bundle_identifier": root_id,
            "watch_apps": [path.relative_to(extraction_root).as_posix() for path in watch_apps],
        }
    )
    if not watch_apps:
        report.error("Root app has no embedded Watch/*.app or WatchKit/*.app")
    for watch_app in watch_apps:
        check_watch_app(watch_app, root_id, report, require_signature)

    return extraction_root


def run_codesign(extraction_root: Path, report: Report) -> None:
    codesign = shutil.which("codesign")
    if not codesign:
        report.error("--verify-codesign requested, but codesign is unavailable (run on macOS)")
        return
    root_app = extraction_root / "Payload" / str(report.facts["root_app"])
    result = subprocess.run(
        [codesign, "--verify", "--deep", "--strict", "--verbose=2", str(root_app)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().replace("\n", " | ")
        report.error(f"codesign verification failed: {detail}")
    else:
        report.facts["codesign_verified"] = True


def print_report(report: Report, json_output: bool) -> None:
    if json_output:
        print(json.dumps({"facts": report.facts, "warnings": report.warnings, "errors": report.errors}, indent=2))
        return

    for key, value in report.facts.items():
        if key == "extraction_root":
            continue
        print(f"{key}: {value}")
    for warning in report.warnings:
        print(f"WARNING: {warning}")
    for error in report.errors:
        print(f"ERROR: {error}")
    if not report.errors:
        print("PASS: Watch IPA package validation succeeded")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument(
        "--structure-only",
        action="store_true",
        help="validate Watch structure without requiring profiles and CodeResources",
    )
    parser.add_argument(
        "--verify-codesign",
        action="store_true",
        help="also run codesign --verify --deep --strict (requires macOS)",
    )
    parser.add_argument("--json", action="store_true", dest="json_output")
    args = parser.parse_args()

    report = Report()
    extraction_root = validate_zip(args.ipa, report, require_signature=not args.structure_only)
    if extraction_root is not None and args.verify_codesign and not report.errors:
        run_codesign(extraction_root, report)

    print_report(report, args.json_output)
    if extraction_root is not None:
        shutil.rmtree(extraction_root, ignore_errors=True)
    return 1 if report.errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
