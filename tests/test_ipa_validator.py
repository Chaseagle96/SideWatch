from __future__ import annotations

import plistlib
import stat
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY_ROOT / "scripts"))

from validate_ipa import validate_ipa  # noqa: E402


def macho_stub() -> bytes:
    return struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0)


def base_info(identifier: str, executable: str, *, watch: bool, package_type: str) -> dict:
    return {
        "CFBundleIdentifier": identifier,
        "CFBundleExecutable": executable,
        "CFBundleName": executable,
        "CFBundleDisplayName": executable,
        "CFBundlePackageType": package_type,
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "CFBundleSupportedPlatforms": ["WatchOS" if watch else "iPhoneOS"],
        "DTPlatformName": "watchos" if watch else "iphoneos",
        "UIDeviceFamily": [4] if watch else [1, 2],
        "MinimumOSVersion": "9.0" if watch else "15.0",
    }


class FixtureBuilder:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.payload = root / "Payload"
        self.app = self.bundle(
            self.payload / "Fixture.app",
            base_info("com.example.fixture", "Fixture", watch=False, package_type="APPL"),
        )

    def bundle(self, path: Path, info: dict) -> Path:
        path.mkdir(parents=True, exist_ok=True)
        (path / "Info.plist").write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        executable = path / info["CFBundleExecutable"]
        executable.write_bytes(macho_stub())
        executable.chmod(0o755)
        return path

    def ios_extension(self) -> Path:
        info = base_info(
            "com.example.fixture.widget", "Widget", watch=False, package_type="XPC!"
        )
        info["NSExtension"] = {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}
        return self.bundle(self.app / "PlugIns" / "Widget.appex", info)

    def watch_app(self) -> Path:
        info = base_info(
            "com.example.fixture.watchkitapp", "FixtureWatch", watch=True, package_type="APPL"
        )
        info["WKApplication"] = True
        info["WKCompanionAppBundleIdentifier"] = "com.example.fixture"
        return self.bundle(self.app / "Watch" / "FixtureWatch.app", info)

    def watch_extension(self, watch_app: Path) -> Path:
        info = base_info(
            "com.example.fixture.watchkitapp.watchkitextension",
            "FixtureWatchExtension",
            watch=True,
            package_type="XPC!",
        )
        info["NSExtension"] = {
            "NSExtensionPointIdentifier": "com.apple.watchkit",
            "NSExtensionAttributes": {
                "WKAppBundleIdentifier": "com.example.fixture.watchkitapp"
            },
        }
        return self.bundle(
            watch_app / "PlugIns" / "FixtureWatchExtension.appex", info
        )

    def framework(self, parent: Path, name: str) -> Path:
        info = base_info(
            f"com.example.{name.lower()}", name, watch=parent != self.app, package_type="FMWK"
        )
        return self.bundle(parent / "Frameworks" / f"{name}.framework", info)

    def archive(self, destination: Path) -> Path:
        with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(self.root.rglob("*")):
                name = path.relative_to(self.root).as_posix()
                if path.is_dir():
                    info = zipfile.ZipInfo(name + "/")
                    info.external_attr = (stat.S_IFDIR | 0o755) << 16
                    archive.writestr(info, b"")
                else:
                    archive.write(path, name)
        return destination


class IPAValidatorFixtureTests(unittest.TestCase):
    def build_and_validate(self, configure) -> tuple:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        builder = FixtureBuilder(root / "source")
        configure(builder)
        ipa = builder.archive(root / "fixture.ipa")
        report = validate_ipa(
            ipa, require_signature=False, require_watch=False, verify_codesign=False
        )
        self.addCleanup(temporary.cleanup)
        return report, builder

    def test_a_ordinary_ios_application(self) -> None:
        report, _ = self.build_and_validate(lambda _: None)
        self.assertTrue(report.passed)
        self.assertEqual([component.kind for component in report.components], ["iOS application"])

    def test_b_ios_application_with_extension(self) -> None:
        report, _ = self.build_and_validate(lambda builder: builder.ios_extension())
        self.assertTrue(report.passed)
        self.assertIn("iOS extension", [component.kind for component in report.components])

    def test_c_ios_application_with_watch_companion(self) -> None:
        report, _ = self.build_and_validate(lambda builder: builder.watch_app())
        self.assertTrue(report.passed)
        self.assertEqual(report.facts["watch_application_count"], 1)

    def test_d_watch_companion_and_watch_extension(self) -> None:
        def configure(builder: FixtureBuilder) -> None:
            builder.watch_extension(builder.watch_app())

        report, _ = self.build_and_validate(configure)
        self.assertTrue(report.passed)
        order = report.facts["signing_order"]
        self.assertLess(order.index("Watch/FixtureWatch.app/PlugIns/FixtureWatchExtension.appex"), order.index("Watch/FixtureWatch.app"))
        self.assertLess(order.index("Watch/FixtureWatch.app"), order.index("."))

    def test_e_mixed_modern_application(self) -> None:
        def configure(builder: FixtureBuilder) -> None:
            builder.framework(builder.app, "RootKit")
            builder.ios_extension()
            watch = builder.watch_app()
            builder.framework(watch, "WatchKitSupport")
            builder.watch_extension(watch)

        report, _ = self.build_and_validate(configure)
        self.assertTrue(report.passed)
        self.assertEqual(len(report.components), 6)
        self.assertEqual(report.facts["signing_order"][-1], ".")

    def test_relationship_mismatch_fails(self) -> None:
        def configure(builder: FixtureBuilder) -> None:
            watch = builder.watch_app()
            info_path = watch / "Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info["WKCompanionAppBundleIdentifier"] = "com.example.wrong"
            info_path.write_bytes(plistlib.dumps(info))

        report, _ = self.build_and_validate(configure)
        self.assertFalse(report.passed)
        self.assertTrue(any("WKCompanionAppBundleIdentifier" in error for component in report.components for error in component.errors))

    def test_duplicate_provisioned_identifier_fails(self) -> None:
        def configure(builder: FixtureBuilder) -> None:
            extension = builder.ios_extension()
            info_path = extension / "Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info["CFBundleIdentifier"] = "com.example.fixture"
            info_path.write_bytes(plistlib.dumps(info))

        report, _ = self.build_and_validate(configure)
        self.assertFalse(report.passed)
        self.assertTrue(
            any(
                "duplicated by provisioned components" in error
                for component in report.components
                for error in component.errors
            )
        )

    def test_ldid_recursive_contract_includes_watch_roots(self) -> None:
        source = (
            REPOSITORY_ROOT
            / "Dependencies/AltSign/Dependencies/ldid/ldid.cpp"
        ).read_text(encoding="utf-8")
        self.assertIn('Watch/[^/]*\\\\.app', source)
        self.assertIn('WatchKit/[^/]*\\\\.app', source)
        self.assertIn('Starts(name, "Watch/")', source)
        self.assertIn('return "";', source)


if __name__ == "__main__":
    unittest.main()
