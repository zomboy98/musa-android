# libsmb2-r9 for private Android CI

These three unmodified Android binaries come from the official
[dart_smb2 libsmb2-r9 release](https://github.com/ales-drnz/dart_smb2/releases/tag/libsmb2-r9).
They are the assets expected by the hook in dart_smb2 0.2.3.

| ABI | GitHub release asset ID | Bytes |
| --- | --- | --- |
| arm64-v8a | 637455479 | 252248 |
| armeabi-v7a | 637455480 | 238784 |
| x86_64 | 637455482 | 259016 |

The release assets were obtained through
[`GET /repos/{owner}/{repo}/releases/assets/{asset_id}`](https://docs.github.com/en/rest/releases/assets#get-a-release-asset)
with `Accept: application/octet-stream`. The binaries match both the release
digests and the hashes hardcoded in the dart_smb2 0.2.3 hook.
`manifest.json` and `SHA256SUMS` are the official release files, including
entries for other platforms. Only the Android binaries are included here.

The release declares LGPL-2.1-or-later for libsmb2. `COPYING` describes
component licenses, and `LICENCE-LGPL-2.1.txt` contains the LGPL text. The
source snapshot also contains the DCE/RPC BSD notice.

## Source and build recipe

- `libsmb2-e94eee9465d55ed094ace2c038a8705b4822dada.tar.gz` is the
  [upstream source snapshot](https://github.com/sahlberg/libsmb2/tree/e94eee9465d55ed094ace2c038a8705b4822dada).
  Its SHA-256 matches the release manifest
  (`7f347c08c8cb66a94e42d1cac4686e71a093a7022e7e77cb5cc9325b8369b0ce`).
- `libsmb2-scripts-f2695f24c0db8984cd0593738b72004ab48cfe1b.tar.gz` is the
  [release recipe snapshot](https://github.com/ales-drnz/libsmb2-scripts/tree/f2695f24c0db8984cd0593738b72004ab48cfe1b),
  identified by the release manifest. The SHA-256 of the included archive is
  `66c302f2a5555109f2e44d0641ce03f95f2668543d7f947b7396eb3df0c33e53`.
  It includes the Android build script, source preparation helpers, shared
  patches, build workflow and its own license.

See the recipe snapshot's `scripts/build_libsmb2_android.sh` and
`scripts/export_sources.sh` for the build and patched-source preparation.
The release binaries were verified by digest. They were not rebuilt from the
snapshots for this import.

CI reads the binaries from its private checkout and verifies the selected ABIs
before applying the local hook override. Access to this private directory does
not itself provide source access to APK recipients. Any APK distribution
outside the private CI must separately arrange the applicable notices and
corresponding-source access for recipients.
