# Module taxonomy proposal — NOT IMPLEMENTED OR EXECUTED

Actual build10 APK inventory:19 bundled shared libraries; current Kotlin allowlist
recognizes only libflutter.so among them.18 legitimate packaged candidates are
absent, including libc++_shared.so, libmornye_audio.so, libmornye_mobile.so,
libdartjni.so, libffmpegkit.so and FFmpeg libav*/libsw* libraries. Presence in APK
is NOT evidence that they loaded, participated in this route or caused the crash.
Instrumentation APK itself contains no .so entries. Inventory and proposed fixed
registry live in build10/native-module-inventory.json and
native-module-candidate-registry-PROPOSAL.json (NOT consumed by any parser).

Official AOSP targets/dependencies also include missing candidates such as
libaudioeffect_jni.so, libandroid_runtime.so, libnativehelper.so, libutils.so,
libbinder.so, libmedia.so, libmedia_jni_utils.so, libstagefright_foundation.so,
libaudioutils.so and libaudiofoundation.so. This verifies legitimate Android
component names, not their actual Samsung/OEM presence or guilt. Sources:
https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/media/jni/Android.bp
https://android.googlesource.com/platform/frameworks/base/+/master/media/jni/audioeffect/Android.bp

Current trace:4 named/crashing-thread frames, all PC present, all basenames outside
fixed allowlist. This is compatible with bundled/system candidates above, ownAPK
container mappings or other named mappings; the saved counts cannot choose among
them or recover names. No widening based solely on a guessed crash culprit.

Proposed privacy-preserving next projection, requiring separate review/build/run:
- Register finite candidateIDs from the exact verified APK inventory and cited
  AOSP targets, with SHA256 of each known basename generated offline.
- In the already-owned/nonce-correlated process trace, normalize file_name only
  in memory; compare SHA256(basename) against that precommitted registry.
- Emit only the fixed candidateID plus explicit relativePC when matched. NEVER
  emit/hash-persist an unknown name, full path, symbol, build-ID, memory or bytes.
- Unmatched names remain OTHER_NAMED numeric count. A candidate match identifies
  a basename, not the particular loaded ELF or root cause; stronger provenance
  would require separately reviewed build-ID matching against known APK entries.
- OWN_APK_CONTAINER category is permitted only after comparing the full transient
  mapping name to Context.applicationInfo.sourceDir/splitSourceDirs EXACTLY; do
  not classify arbitrary base.apk by basename. Retain no path. A container PC
  is not automatically a specific library PC: file_map_offset/ZIP entry mapping
  would require a distinct verified resolver before library attribution.

No active allowlist changed. Candidate registry values come solely from own build
artifacts/AOSP, never the crash. UnknownFields0 is not a schema audit. No new
S24/build/test or trace retrieval performed for this proposal; raw old trace was
never saved and cannot be revisited.
