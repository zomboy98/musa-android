"""Verify the vendored dart_smb2 assets and configure private Android builds."""

import argparse
import hashlib
from pathlib import Path
import re


ASSET_DIR = Path("third_party/libsmb2-r9")
SHA256 = {
    "arm64-v8a": "d9af2446788f5eb298065312fcb21b11ebd7af83510bbfb0c09d8a6075bb2cf2",
    "armeabi-v7a": "54d3e5c85fe824f426da21028500a825d1ee4ae7dd46a2cfc8e74f2e4e603d36",
    "x86_64": "e740406fb7e97c2b6aa1eb65864b348a9b720b07c1ff90b75e6e5be12beee205",
}


def verified(path, abi):
    if path.is_symlink() or not path.is_file():
        return False
    with path.open("rb") as asset:
        return hashlib.file_digest(asset, "sha256").hexdigest() == SHA256[abi]


def configure_hook(abis):
    for abi in abis:
        path = ASSET_DIR / f"libsmb2_android-{abi}.so"
        if not verified(path, abi):
            raise ValueError(f"Missing or invalid {path}")
        print(f"Verified {path}")

    lock = Path("pubspec.lock").read_text(encoding="utf-8")
    if not re.search(r'^  dart_smb2:\n(?:^    .+\n)*^    version: "0\.2\.3"$', lock, re.M):
        raise ValueError("Expected dart_smb2 0.2.3 in pubspec.lock")

    manifest = Path("pubspec.yaml")
    content = manifest.read_bytes()
    newline = b"\r\n" if b"\r\n" in content else b"\n"
    anchor = newline.join((b"hooks:", b"  user_defines:", b""))
    override = newline.join(
        (b"    dart_smb2:", f"      libsmb2: {ASSET_DIR.as_posix()}".encode(), b"")
    )
    if content.count(anchor) != 1:
        raise ValueError("Expected one hooks.user_defines block in pubspec.yaml")
    if anchor + override in content:
        return
    if b"    dart_smb2:" in content:
        raise ValueError("Unexpected existing dart_smb2 hook configuration")
    manifest.write_bytes(content.replace(anchor, anchor + override, 1))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("abis", choices=SHA256, nargs="+")
    args = parser.parse_args()
    try:
        configure_hook(args.abis)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Android libsmb2: {error}\n")


if __name__ == "__main__":
    main()
