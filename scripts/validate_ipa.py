#!/usr/bin/env python3
"""Recursively validate an iOS IPA and every nested signed component."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import plistlib
import shutil
import stat
import struct
import subprocess
import tempfile
import zipfile
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Any, Iterable


MACHO_MAGICS = {
    b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
    b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE7171
CSSLOT_ENTITLEMENTS = 5


@dataclass
class Component:
    path: Path
    relative_path: str
    kind: str
    platform: str
    info: dict[str, Any] = field(default_factory=dict)
    bundle_id: str | None = None
    executable: Path | None = None
    children: list["Component"] = field(default_factory=list)
    profile: dict[str, Any] | None = None
    signing_entitlements: dict[str, Any] | None = None
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    relationships_valid: bool = True
    static_signature_valid: bool = False
    codesign_valid: bool | None = None

    @property
    def requires_profile(self) -> bool:
        return self.kind in {
            "iOS application", "iOS extension", "watchOS application",
            "watchOS extension", "embedded application",
        }

    @property
    def requires_code_resources(self) -> bool:
        return self.kind != "dynamic library"

    def postorder(self) -> list["Component"]:
        return [node for child in self.children for node in child.postorder()] + [self]


@dataclass
class ValidationReport:
    ipa: Path
    components: list[Component] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    facts: dict[str, Any] = field(default_factory=dict)

    def error(self, message: str, component: Component | None = None) -> None:
        (self.errors if component is None else component.errors).append(message)

    def warning(self, message: str, component: Component | None = None) -> None:
        (self.warnings if component is None else component.warnings).append(message)

    @property
    def passed(self) -> bool:
        return not self.errors and all(not component.errors for component in self.components)


def read_plist(path: Path) -> dict[str, Any] | None:
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException):
        return None
    return value if isinstance(value, dict) else None


def is_watch_info(info: dict[str, Any]) -> bool:
    platforms = info.get("CFBundleSupportedPlatforms", [])
    if isinstance(platforms, str):
        platforms = [platforms]
    if any(isinstance(value, str) and value.casefold() == "watchos" for value in platforms):
        return True
    platform = info.get("DTPlatformName")
    if isinstance(platform, str) and platform.casefold() == "watchos":
        return True
    families = info.get("UIDeviceFamily", [])
    if isinstance(families, int):
        families = [families]
    return 4 in families


def classify(path: Path, info: dict[str, Any], root: bool = False) -> tuple[str, str]:
    watch = is_watch_info(info)
    platform = "watchOS" if watch else "iOS"
    suffix = path.suffix.casefold()
    if suffix == ".appex":
        return ("watchOS extension" if watch else "iOS extension", platform)
    if suffix == ".framework":
        return ("framework", platform if info else "unknown")
    if suffix == ".dylib":
        return ("dynamic library", "unknown")
    if suffix == ".app":
        if watch:
            return ("watchOS application", platform)
        return ("iOS application" if root else "embedded application", platform)
    return ("signed bundle", platform if info else "unknown")


def resolve_executable(component: Component, report: ValidationReport) -> None:
    if component.kind == "dynamic library":
        component.executable = component.path
        return
    name = component.info.get("CFBundleExecutable")
    if isinstance(name, str) and name:
        candidate = component.path / name
        if candidate.exists():
            component.executable = candidate
            return
        report.error(f"CFBundleExecutable points to missing file '{name}'.", component)
        return
    candidates: list[Path] = []
    try:
        for candidate in component.path.iterdir():
            if not candidate.is_file() or candidate.name in {"Info.plist", "PkgInfo"}:
                continue
            try:
                if candidate.read_bytes()[:4] in MACHO_MAGICS:
                    candidates.append(candidate)
            except OSError:
                continue
    except OSError:
        pass
    if component.kind == "watchOS application" and len(candidates) == 1:
        component.executable = candidates[0]
        report.warning(f"CFBundleExecutable is missing; inferred '{candidates[0].name}'.", component)
    else:
        report.error("CFBundleExecutable is missing or cannot be inferred uniquely.", component)


def discover_component(path: Path, root_path: Path, report: ValidationReport, root: bool = False) -> Component:
    info = {} if path.suffix.casefold() == ".dylib" else (read_plist(path / "Info.plist") or {})
    kind, platform = classify(path, info, root=root)
    relative = "." if path == root_path else path.relative_to(root_path).as_posix()
    component = Component(
        path=path,
        relative_path=relative,
        kind=kind,
        platform=platform,
        info=info,
        bundle_id=info.get("CFBundleIdentifier") if isinstance(info.get("CFBundleIdentifier"), str) else None,
    )
    report.components.append(component)
    if kind != "dynamic library":
        if not info:
            report.error("Info.plist is missing or unreadable.", component)
        if kind != "framework" and not component.bundle_id:
            report.error("CFBundleIdentifier is missing.", component)
        resolve_executable(component, report)

    child_paths: list[Path] = []
    for directory_name, suffixes in (
        ("PlugIns", {".appex", ".app"}),
        ("Watch", {".app"}),
        ("WatchKit", {".app"}),
        ("Frameworks", {".framework", ".dylib"}),
    ):
        directory = path / directory_name
        if not directory.is_dir():
            continue
        try:
            child_paths.extend(
                child for child in directory.iterdir()
                if child.suffix.casefold() in suffixes
                and (child.is_dir() or child.suffix.casefold() == ".dylib")
            )
        except OSError as exc:
            report.error(f"Cannot enumerate {directory_name}/: {exc}", component)

    seen: set[Path] = set()
    for child_path in sorted(child_paths, key=lambda item: item.as_posix()):
        resolved = child_path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        component.children.append(discover_component(child_path, root_path, report))
    return component


def validate_zip_paths(archive: zipfile.ZipFile, report: ValidationReport) -> None:
    for entry in archive.infolist():
        path = PurePosixPath(entry.filename)
        if path.is_absolute() or ".." in path.parts:
            report.error(f"Unsafe ZIP path: {entry.filename}")
        mode = (entry.external_attr >> 16) & 0o177777
        if not stat.S_ISLNK(mode):
            continue
        try:
            target = archive.read(entry).decode("utf-8")
        except (KeyError, UnicodeDecodeError) as exc:
            report.error(f"Unreadable symlink {entry.filename}: {exc}")
            continue
        if PurePosixPath(target).is_absolute():
            report.error(f"Absolute symlink target in IPA: {entry.filename} -> {target}")
            continue
        depth = 0
        for part in path.parent.joinpath(PurePosixPath(target)).parts:
            depth += -1 if part == ".." else (0 if part in {"", "."} else 1)
            if depth < 0:
                report.error(f"Symlink escapes IPA root: {entry.filename} -> {target}")
                break


def extract_archive(archive: zipfile.ZipFile, destination: Path) -> None:
    for entry in archive.infolist():
        path = destination.joinpath(*PurePosixPath(entry.filename).parts)
        mode = (entry.external_attr >> 16) & 0o177777
        if entry.is_dir():
            path.mkdir(parents=True, exist_ok=True)
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        if stat.S_ISLNK(mode):
            try:
                path.symlink_to(archive.read(entry).decode("utf-8"))
            except FileExistsError:
                pass
            continue
        with archive.open(entry) as source, path.open("wb") as output:
            shutil.copyfileobj(source, output)
        permissions = stat.S_IMODE(mode)
        if permissions:
            path.chmod(permissions)


def decode_profile(path: Path) -> dict[str, Any] | None:
    try:
        data = path.read_bytes()
    except OSError:
        return None
    start = data.find(b"<?xml")
    end = data.find(b"</plist>", start)
    if start < 0 or end < 0:
        return None
    try:
        value = plistlib.loads(data[start : end + len(b"</plist>")])
    except (ValueError, plistlib.InvalidFileException):
        return None
    return value if isinstance(value, dict) else None


def cpu_name(cpu_type: int) -> str:
    return {
        7: "i386", 0x01000007: "x86_64", 12: "arm",
        0x0100000C: "arm64", 0x0200000C: "arm64_32",
    }.get(cpu_type, hex(cpu_type))


def thin_macho_regions(data: bytes) -> Iterable[tuple[int, int, str]]:
    if len(data) < 4:
        return
    magic = data[:4]
    if magic in {b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf", b"\xbe\xba\xfe\xca", b"\xbf\xba\xfe\xca"}:
        big_endian = magic in {b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"}
        is_64 = magic in {b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
        endian = ">" if big_endian else "<"
        count = struct.unpack_from(endian + "I", data, 4)[0]
        size = 32 if is_64 else 20
        for index in range(count):
            base = 8 + index * size
            if base + size > len(data):
                break
            cpu_type = struct.unpack_from(endian + "I", data, base)[0]
            fmt = "QQ" if is_64 else "II"
            offset, length = struct.unpack_from(endian + fmt, data, base + 8)
            yield int(offset), int(length), cpu_name(cpu_type)
        return
    yield 0, len(data), "unknown"


def parse_entitlements_blob(blob: bytes) -> dict[str, Any] | None:
    if len(blob) < 12 or struct.unpack_from(">I", blob, 0)[0] != CSMAGIC_EMBEDDED_SIGNATURE:
        return None
    count = struct.unpack_from(">I", blob, 8)[0]
    for index in range(count):
        base = 12 + index * 8
        if base + 8 > len(blob):
            break
        slot, offset = struct.unpack_from(">II", blob, base)
        if slot != CSSLOT_ENTITLEMENTS or offset + 8 > len(blob):
            continue
        magic, length = struct.unpack_from(">II", blob, offset)
        if magic != CSMAGIC_EMBEDDED_ENTITLEMENTS or offset + length > len(blob):
            continue
        try:
            value = plistlib.loads(blob[offset + 8 : offset + length])
        except (ValueError, plistlib.InvalidFileException):
            return None
        return value if isinstance(value, dict) else None
    return None


def macho_signature_info(path: Path) -> tuple[bool, list[str], dict[str, Any] | None]:
    try:
        data = path.read_bytes()
    except OSError:
        return False, [], None
    found_signature = False
    architectures: list[str] = []
    found_entitlements: dict[str, Any] | None = None
    for offset, length, fat_arch in thin_macho_regions(data):
        thin = data[offset : offset + length]
        if len(thin) < 28:
            continue
        magic = thin[:4]
        if magic in {b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe"}:
            endian = "<"
        elif magic in {b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf"}:
            endian = ">"
        else:
            continue
        is_64 = magic in {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"}
        cpu_type = struct.unpack_from(endian + "I", thin, 4)[0]
        architectures.append(cpu_name(cpu_type) if fat_arch == "unknown" else fat_arch)
        command_count = struct.unpack_from(endian + "I", thin, 16)[0]
        command_offset = 32 if is_64 else 28
        for _ in range(command_count):
            if command_offset + 8 > len(thin):
                break
            command, command_size = struct.unpack_from(endian + "II", thin, command_offset)
            if command_size < 8 or command_offset + command_size > len(thin):
                break
            if command == LC_CODE_SIGNATURE and command_size >= 16:
                data_offset, data_size = struct.unpack_from(endian + "II", thin, command_offset + 8)
                if data_size and data_offset + data_size <= len(thin):
                    found_signature = True
                    found_entitlements = parse_entitlements_blob(thin[data_offset : data_offset + data_size]) or found_entitlements
            command_offset += command_size
    return found_signature, sorted(set(architectures)), found_entitlements


def wildcard_permits(pattern: str, candidate: str) -> bool:
    return pattern == "*" or (candidate.startswith(pattern[:-1]) if pattern.endswith("*") else pattern == candidate)


def entitlement_values_permitted(permitted: Any, actual: Any) -> bool:
    if isinstance(permitted, str) and isinstance(actual, str):
        return wildcard_permits(permitted, actual)
    if isinstance(permitted, list) and isinstance(actual, list):
        for actual_value in actual:
            if isinstance(actual_value, str):
                if not any(isinstance(value, str) and wildcard_permits(value, actual_value) for value in permitted):
                    return False
            elif actual_value not in permitted:
                return False
        return True
    return permitted == actual


def validate_profile_and_signature(
    component: Component,
    report: ValidationReport,
    require_signature: bool,
    expected_device_udid: str | None = None,
) -> None:
    if component.executable is None:
        return
    try:
        if component.kind != "dynamic library" and not component.executable.stat().st_mode & stat.S_IXUSR:
            report.error("Main executable is not marked executable in the IPA.", component)
    except OSError as exc:
        report.error(f"Cannot stat executable: {exc}", component)
        return
    has_signature, architectures, entitlements = macho_signature_info(component.executable)
    component.signing_entitlements = entitlements
    component.info["_SideWatchArchitectures"] = architectures
    if not has_signature:
        (report.error if require_signature else report.warning)("Mach-O has no LC_CODE_SIGNATURE payload.", component)
    code_resources = component.path / "_CodeSignature" / "CodeResources"
    if component.requires_code_resources and not code_resources.is_file():
        (report.error if require_signature else report.warning)("_CodeSignature/CodeResources is missing.", component)
    if not component.requires_profile:
        component.static_signature_valid = has_signature and (not component.requires_code_resources or code_resources.is_file())
        return

    profile_path = component.path / "embedded.mobileprovision"
    if not profile_path.is_file():
        (report.error if require_signature else report.warning)("embedded.mobileprovision is missing.", component)
        return
    profile = decode_profile(profile_path)
    if profile is None:
        report.error("embedded.mobileprovision cannot be decoded.", component)
        return
    component.profile = profile
    profile_entitlements = profile.get("Entitlements")
    if not isinstance(profile_entitlements, dict):
        report.error("Provisioning profile has no Entitlements dictionary.", component)
        return
    teams = profile.get("TeamIdentifier", [])
    team = teams[0] if isinstance(teams, list) and teams else None
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, dt.datetime):
        report.error("Provisioning profile has no valid ExpirationDate.", component)
    else:
        now = dt.datetime.now(dt.timezone.utc)
        if expiration.tzinfo is None:
            expiration = expiration.replace(tzinfo=dt.timezone.utc)
        if expiration <= now:
            report.error(f"Provisioning profile expired at {expiration.isoformat()}.", component)
    developer_certificates = profile.get("DeveloperCertificates")
    if not isinstance(developer_certificates, list) or not any(
        isinstance(value, bytes) and value for value in developer_certificates
    ):
        report.error("Provisioning profile contains no developer certificate.", component)
    if expected_device_udid is not None:
        provisioned_devices = profile.get("ProvisionedDevices", [])
        if not isinstance(provisioned_devices, list) or expected_device_udid not in provisioned_devices:
            report.error(
                f"Provisioning profile does not contain target device '{expected_device_udid}'.",
                component,
            )
    app_identifier = profile_entitlements.get("application-identifier")
    if not isinstance(app_identifier, str):
        report.error("Profile application-identifier is missing.", component)
    elif component.bundle_id and team:
        expected = f"{team}.{component.bundle_id}"
        if not wildcard_permits(app_identifier, expected):
            report.error(f"Profile application-identifier '{app_identifier}' does not permit '{expected}'.", component)
    profile_team = profile_entitlements.get("com.apple.developer.team-identifier")
    if team and profile_team != team:
        report.error(f"Profile team entitlement {profile_team!r} does not match TeamIdentifier {team!r}.", component)
    if entitlements is None:
        (report.error if require_signature else report.warning)("Signing entitlements could not be extracted from the Mach-O signature.", component)
    else:
        binary_app_identifier = entitlements.get("application-identifier")
        if isinstance(app_identifier, str) and binary_app_identifier != app_identifier:
            report.error(f"Signed application-identifier {binary_app_identifier!r} does not match profile {app_identifier!r}.", component)
        for key, actual in entitlements.items():
            if key not in profile_entitlements:
                report.error(f"Signed entitlement '{key}' is absent from the profile.", component)
            elif not entitlement_values_permitted(profile_entitlements[key], actual):
                report.error(f"Signed entitlement '{key}' exceeds the profile value.", component)
    component.static_signature_valid = has_signature and code_resources.is_file() and component.profile is not None and not component.errors


def validate_relationships(root: Component, report: ValidationReport) -> None:
    def walk(component: Component, parent: Component | None) -> None:
        if component.kind == "watchOS application":
            companion = component.info.get("WKCompanionAppBundleIdentifier")
            if companion != root.bundle_id:
                component.relationships_valid = False
                report.error(f"WKCompanionAppBundleIdentifier {companion!r} does not match root {root.bundle_id!r}.", component)
        if component.kind == "watchOS extension":
            extension = component.info.get("NSExtension")
            attributes = extension.get("NSExtensionAttributes") if isinstance(extension, dict) else None
            watch_identifier = attributes.get("WKAppBundleIdentifier") if isinstance(attributes, dict) else None
            expected = parent.bundle_id if parent and parent.kind == "watchOS application" else None
            if watch_identifier != expected:
                component.relationships_valid = False
                report.error(f"WKAppBundleIdentifier {watch_identifier!r} does not match parent Watch app {expected!r}.", component)
            point = extension.get("NSExtensionPointIdentifier") if isinstance(extension, dict) else None
            if not isinstance(point, str) or "watchkit" not in point.casefold():
                component.relationships_valid = False
                report.error("NSExtensionPointIdentifier is not a WatchKit extension point.", component)
        for child in component.children:
            walk(child, component)
    walk(root, None)


def validate_graph_invariants(root: Component, report: ValidationReport) -> None:
    provisioned = [component for component in root.postorder() if component.requires_profile]
    identifiers: dict[str, list[Component]] = {}
    for component in provisioned:
        if component.bundle_id:
            identifiers.setdefault(component.bundle_id, []).append(component)

        expected_package_type = (
            "XPC!" if component.kind.endswith("extension") else "APPL"
        )
        actual_package_type = component.info.get("CFBundlePackageType")
        if actual_package_type != expected_package_type:
            report.error(
                f"CFBundlePackageType {actual_package_type!r} must be {expected_package_type!r}.",
                component,
            )

        platforms = component.info.get("CFBundleSupportedPlatforms", [])
        if isinstance(platforms, str):
            platforms = [platforms]
        expected_platform = "WatchOS" if component.platform == "watchOS" else "iPhoneOS"
        if not any(
            isinstance(value, str) and value.casefold() == expected_platform.casefold()
            for value in platforms
        ):
            report.error(
                f"CFBundleSupportedPlatforms does not contain {expected_platform!r}.",
                component,
            )

    for identifier, components in identifiers.items():
        if len(components) <= 1:
            continue
        paths = ", ".join(component.relative_path for component in components)
        for component in components:
            report.error(
                f"Bundle identifier '{identifier}' is duplicated by provisioned components: {paths}.",
                component,
            )


def validate_team_consistency(root: Component, report: ValidationReport) -> None:
    teams: dict[str, list[Component]] = {}
    for component in root.postorder():
        if not component.requires_profile or component.profile is None:
            continue
        identifiers = component.profile.get("TeamIdentifier", [])
        if isinstance(identifiers, list) and identifiers and isinstance(identifiers[0], str):
            teams.setdefault(identifiers[0], []).append(component)
    if len(teams) <= 1:
        return
    summary = "; ".join(
        f"{team}: {', '.join(component.relative_path for component in components)}"
        for team, components in sorted(teams.items())
    )
    report.error(f"Provisioned components use multiple developer teams: {summary}")


def run_codesign(component: Component, report: ValidationReport) -> None:
    codesign = shutil.which("codesign")
    if codesign is None:
        report.error("--verify-codesign was requested, but codesign is unavailable.")
        return
    result = subprocess.run(
        [codesign, "--verify", "--strict", "--verbose=4", str(component.path)],
        capture_output=True, text=True, check=False,
    )
    component.codesign_valid = result.returncode == 0
    if result.returncode:
        detail = (result.stderr or result.stdout).strip().replace("\n", " | ")
        report.error(f"codesign --verify --strict failed: {detail}", component)
        return

    if not component.requires_profile or component.profile is None:
        return

    with tempfile.TemporaryDirectory(prefix="sidewatch-cert-") as temporary:
        prefix = Path(temporary) / "signer-"
        extraction = subprocess.run(
            [
                codesign, "--display", "--extract-certificates", str(prefix),
                str(component.path),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        certificates = sorted(Path(temporary).glob("signer-*"))
        if extraction.returncode or not certificates:
            detail = (extraction.stderr or extraction.stdout).strip().replace("\n", " | ")
            report.error(f"Could not extract the signing certificate: {detail}", component)
            return
        signer = certificates[0].read_bytes()
        profile_certificates = component.profile.get("DeveloperCertificates", [])
        if not any(isinstance(value, bytes) and value == signer for value in profile_certificates):
            report.error("The code-signing certificate is not authorized by the provisioning profile.", component)


def component_profile_values(component: Component) -> tuple[str, str]:
    if component.profile is None:
        return "-", "-"
    entitlements = component.profile.get("Entitlements", {})
    app_id = entitlements.get("application-identifier", "-") if isinstance(entitlements, dict) else "-"
    teams = component.profile.get("TeamIdentifier", [])
    team = teams[0] if isinstance(teams, list) and teams else "-"
    return str(app_id), str(team)


def report_dict(report: ValidationReport) -> dict[str, Any]:
    rows = []
    for component in report.components:
        profile_app_id, team = component_profile_values(component)
        rows.append({
            "component": component.relative_path,
            "kind": component.kind,
            "platform": component.platform,
            "bundle_id": component.bundle_id,
            "profile_app_id": profile_app_id,
            "team": team,
            "architectures": component.info.get("_SideWatchArchitectures", []),
            "signature": "valid" if component.static_signature_valid else "invalid",
            "codesign": component.codesign_valid,
            "relationships": "valid" if component.relationships_valid else "invalid",
            "errors": component.errors,
            "warnings": component.warnings,
            "result": "PASS" if not component.errors else "FAIL",
        })
    return {
        "ipa": str(report.ipa), "facts": report.facts, "components": rows,
        "errors": report.errors, "warnings": report.warnings,
        "result": "PASS" if report.passed else "FAIL",
    }


def print_markdown(report: ValidationReport) -> None:
    print("| Component | Platform | Bundle ID | Profile App ID | Team | Signature | Relationships | Result |")
    print("|---|---|---|---|---|---|---|---|")
    for component in report.components:
        profile_app_id, team = component_profile_values(component)
        values = [
            f"{component.kind}: {component.relative_path}", component.platform,
            component.bundle_id or "-", profile_app_id, team,
            "PASS" if component.static_signature_valid else "FAIL",
            "PASS" if component.relationships_valid else "FAIL",
            "PASS" if not component.errors else "FAIL",
        ]
        print("| " + " | ".join(value.replace("|", "\\|") for value in values) + " |")
    for warning in report.warnings:
        print(f"WARNING: {warning}")
    for component in report.components:
        for warning in component.warnings:
            print(f"WARNING [{component.relative_path}]: {warning}")
    for error in report.errors:
        print(f"ERROR: {error}")
    for component in report.components:
        for error in component.errors:
            print(f"ERROR [{component.relative_path}]: {error}")
    print(f"{'PASS' if report.passed else 'FAIL'}: recursive IPA validation")


def validate_ipa(
    ipa: Path,
    *,
    require_signature: bool = True,
    require_watch: bool = False,
    verify_codesign: bool = False,
    device_udid: str | None = None,
    watch_device_udid: str | None = None,
) -> ValidationReport:
    report = ValidationReport(ipa=ipa)
    if not ipa.is_file():
        report.error(f"IPA does not exist: {ipa}")
        return report
    try:
        archive = zipfile.ZipFile(ipa)
    except (OSError, zipfile.BadZipFile) as exc:
        report.error(f"IPA is not a readable ZIP: {exc}")
        return report
    extraction_root = Path(tempfile.mkdtemp(prefix="sidewatch-ipa-"))
    try:
        with archive:
            validate_zip_paths(archive, report)
            if report.errors:
                return report
            extract_archive(archive, extraction_root)
        payload = extraction_root / "Payload"
        if not payload.is_dir():
            report.error("IPA is missing Payload/.")
            return report
        root_apps = sorted(
            (path for path in payload.iterdir() if path.suffix.casefold() == ".app" and path.is_dir()),
            key=lambda path: path.name,
        )
        if len(root_apps) != 1:
            report.error(f"Payload must contain exactly one root .app; found {len(root_apps)}.")
            return report
        root = discover_component(root_apps[0], root_apps[0], report, root=True)
        validate_graph_invariants(root, report)
        validate_relationships(root, report)
        for component in root.postorder():
            expected_udid = (
                watch_device_udid
                if component.platform == "watchOS"
                else device_udid
            )
            validate_profile_and_signature(
                component,
                report,
                require_signature,
                expected_device_udid=expected_udid,
            )
            if verify_codesign and not component.errors:
                run_codesign(component, report)
        validate_team_consistency(root, report)
        watch_apps = [component for component in report.components if component.kind == "watchOS application"]
        if require_watch and not watch_apps:
            report.error("No Watch/*.app or WatchKit/*.app component was discovered.")
        report.facts = {
            "root_app": root.path.name,
            "root_bundle_identifier": root.bundle_id,
            "component_count": len(report.components),
            "watch_application_count": len(watch_apps),
            "signing_order": [component.relative_path for component in root.postorder()],
        }
        return report
    finally:
        shutil.rmtree(extraction_root, ignore_errors=True)


def main(argv: list[str] | None = None, *, default_require_watch: bool = False) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--structure-only", action="store_true")
    parser.add_argument("--require-watch", action="store_true", default=default_require_watch)
    parser.add_argument("--verify-codesign", action="store_true")
    parser.add_argument("--device-udid", help="require iOS profiles to contain this device")
    parser.add_argument("--watch-device-udid", help="require watchOS profiles to contain this Watch")
    parser.add_argument("--json", action="store_true", dest="json_output")
    args = parser.parse_args(argv)
    report = validate_ipa(
        args.ipa,
        require_signature=not args.structure_only,
        require_watch=args.require_watch,
        verify_codesign=args.verify_codesign,
        device_udid=args.device_udid,
        watch_device_udid=args.watch_device_udid,
    )
    if args.json_output:
        print(json.dumps(report_dict(report), indent=2, sort_keys=True))
    else:
        print_markdown(report)
    return 0 if report.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
