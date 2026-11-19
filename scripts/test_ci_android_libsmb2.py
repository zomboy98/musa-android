"""Offline regression tests for vendored Android libsmb2 and its hook override."""

import os
from pathlib import Path
import shutil
import tempfile
import unittest

import ci_android_libsmb2 as smb2


class AndroidLibsmb2Test(unittest.TestCase):
    arm_abis = ("arm64-v8a", "armeabi-v7a")
    x64_abis = ("x86_64",)
    vendor = Path(__file__).resolve().parents[1] / smb2.ASSET_DIR

    def setUp(self):
        workspace = tempfile.TemporaryDirectory()
        self.addCleanup(workspace.cleanup)
        previous = Path.cwd()
        os.chdir(workspace.name)
        self.addCleanup(os.chdir, previous)
        smb2.ASSET_DIR.mkdir(parents=True)
        self.manifest = Path("pubspec.yaml")
        self.original = b"hooks:\r\n  user_defines:\r\n    sqlite3:\r\n      source:\r\n        android: system\r\n"
        self.manifest.write_bytes(self.original)
        Path("pubspec.lock").write_text(
            'packages:\n  dart_smb2:\n    dependency: "direct main"\n    version: "0.2.3"\n',
            encoding="utf-8",
        )

    def copy_asset(self, abi):
        name = f"libsmb2_android-{abi}.so"
        return Path(shutil.copyfile(self.vendor / name, smb2.ASSET_DIR / name))

    def test_release_selects_verified_arm_assets_and_preserves_sqlite(self):
        for abi in self.arm_abis:
            self.copy_asset(abi)
        smb2.configure_hook(self.arm_abis)
        smb2.configure_hook(self.arm_abis)
        self.assertEqual(
            self.manifest.read_bytes(),
            self.original.replace(
                b"    sqlite3:",
                b"    dart_smb2:\r\n      libsmb2: third_party/libsmb2-r9\r\n    sqlite3:",
            ),
        )

    def test_diagnostics_selects_verified_x64_asset(self):
        self.copy_asset("x86_64")
        smb2.configure_hook(self.x64_abis)
        self.assertIn(b"libsmb2: third_party/libsmb2-r9", self.manifest.read_bytes())

    def test_missing_asset_refuses_override(self):
        self.copy_asset("arm64-v8a")
        with self.assertRaisesRegex(ValueError, "Missing or invalid .*armeabi-v7a"):
            smb2.configure_hook(self.arm_abis)
        self.assertEqual(self.manifest.read_bytes(), self.original)

    def test_corrupt_asset_refuses_override(self):
        x64 = self.copy_asset("x86_64")
        x64.write_bytes(x64.read_bytes() + b"tampered")
        with self.assertRaisesRegex(ValueError, "Missing or invalid .*x86_64"):
            smb2.configure_hook(self.x64_abis)
        self.assertEqual(self.manifest.read_bytes(), self.original)

    def test_asset_from_different_abi_refuses_override(self):
        arm = self.copy_asset("arm64-v8a")
        arm.rename(smb2.ASSET_DIR / "libsmb2_android-x86_64.so")
        with self.assertRaisesRegex(ValueError, "Missing or invalid .*x86_64"):
            smb2.configure_hook(self.x64_abis)
        self.assertEqual(self.manifest.read_bytes(), self.original)

    def test_mismatched_lock_version_refuses_override(self):
        self.copy_asset("x86_64")
        Path("pubspec.lock").write_text(
            'packages:\n  dart_smb2:\n    version: "0.2.4"\n'
            '  another_package:\n    version: "0.2.3"\n',
            encoding="utf-8",
        )
        with self.assertRaisesRegex(ValueError, "Expected dart_smb2 0.2.3"):
            smb2.configure_hook(self.x64_abis)
        self.assertEqual(self.manifest.read_bytes(), self.original)


if __name__ == "__main__":
    unittest.main()
