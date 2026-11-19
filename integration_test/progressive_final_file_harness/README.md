# Prepared offline Flutter/Media3 final-file harness

**NOT BUILT / NOT EXECUTED. Do not install or run until review and artifact checks.**
No production manifest, connectivity setting or existing package was changed.

## Scope

Paired files:

- integration_test/android_progressive_final_file_test.dart: headless Dart main,
  real MusicPlayerHandler and a real AudioplayersPlaybackDeck with delegating spy.
- android/app/src/androidTest/kotlin/com/zarz/mornye/ProgressiveFlutterFinalFileInstrumentedTest.kt:
  JUnit host, own FlutterEngine with auto-registration disabled, explicit local
  plugins, real progressive/audio channels, synthetic in-memory session/lease.

The producer withholds 1024 bytes. Dart observes early native Media3 progress,
pauses and enables EQ through the actual listener/channel. Real retirement and
result events lead to final MediaPlayer loading while preserving pause/position.
No attached/retired/result event is fabricated. Catalog acquisition, persistence
and Cast are explicit fixtures; this does not test UniFFI or a real provider.
An unexpected application-backend call fails instead of starting a real fallback.

## Network isolation without changing device connectivity

The overlays remove INTERNET from BOTH APKs, including conditional declarations.
Android UID permission enforcement then blocks native/Dart Internet sockets from
process startup. HttpOverrides and a single backend guard do not provide this
guarantee. No Wi-Fi/mobile-data/VPN/firewall or MUSA changes are required.

The init script modifies only the selected invocation's manifest source paths;
normal source manifests/build scripts stay unchanged. It has not been verified
against AGP: refuse installation if configuration fails, either APK retains
INTERNET, or sharedUserId is present. Inspect artifacts before installing and
installed permissions/UID before starting any app component.

Standalone ADB instrumentation uses the system/ADB connection. Do NOT use Flutter
drive/test or a VM-service connection: those require sockets denied to this APK.

## Reproducible build plan — prepared commands, not executed

Run later from the repository root with an explicitly authorized lab device or
emulator. No S24 is selected by this document. Keep prior environment values and
restore them after building. Current cached Rust/bindings must match the ABI.

PowerShell variables:

    $taskRepo = (Get-Location).Path
    $taskHarness = Join-Path $taskRepo 'integration_test/progressive_final_file_harness'
    $taskEntry = Join-Path $taskRepo 'integration_test/android_progressive_final_file_test.dart'
    $taskGradle = 'D:/Datos/Caches/Gradle-wrapper/gradle-9.6.1-bin/4ticwg1pgcbps2hj28r8so764/gradle-9.6.1/bin/gradle.bat'
    $env:JAVA_HOME = 'C:/Program Files/Eclipse Adoptium/jdk-25.0.2.10-hotspot'
    $env:MUSA_BASH_EXECUTABLE = 'C:/Program Files/Git/bin/bash.exe'
    $env:MORNYE_CATALOG_INTEGRATION = '1'
    $env:MORNYE_RUST_ANDROID_ABIS = 'arm64-v8a'
    $taskDefines = (@('MORNYE_EXPERIMENTAL_PROGRESSIVE=true','MORNYE_EXPERIMENTAL_MEDIA3=true') | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) }) -join ','

From the android directory, a single command:

    rtk cmd /c $taskGradle :app:assembleDebug :app:assembleDebugAndroidTest --offline --max-workers=2 --console=plain -x :app:buildRustBackend "-Ptarget=$taskEntry" "-Pdart-defines=$taskDefines" '-Pkotlin.incremental=false' '-Pkotlin.compiler.execution.strategy=in-process' "-PmusaProgressiveOfflineManifestDir=$taskHarness" -I (Join-Path $taskHarness 'offline.init.gradle')

Require exit 0. Missing offline dependencies block the test; no downloading is
authorized by this plan. Rust regeneration is excluded, not linkage checks.
Do not use the earlier JVM exclusion script or exclude source from this build.

## Mandatory APK and packaged-entry checks

Find the two newly generated APKs under build/app/outputs/apk; never silently use
older files. Record source/fixture/kernel/APK SHA-256 and timestamps.

Local SDK analyzer:
D:/Aplicaciones/Android-SDK/cmdline-tools/latest/bin/apkanalyzer.bat

For BOTH APKs, prefix batch commands with rtk cmd /c and inspect:

    apkanalyzer.bat manifest application-id APK
    apkanalyzer.bat manifest permissions APK
    apkanalyzer.bat manifest print APK

Require exact target org.musa.music.catalogintegration and instrumentation
org.musa.music.catalogintegration.test targeting that app. Require no INTERNET
(normal or uses-permission-sdk-23) and no sharedUserId. Inspect merged manifest
reports too. Any mismatch is a blocker, not a warning.

Validate packaged Dart, not merely the command line:

1. Save build log/task inputs showing the absolute target Dart file above.
2. Read ZIP entry assets/flutter_assets/kernel_blob.bin locally using
   System.IO.Compression.ZipFile; record its hash.
3. Require binary strings musa.test/progressive_final_file,
   android_progressive_final_file_test.dart, and
   Native paired instrumentation harness is absent.
4. These are necessary identity checks, not proof of the kernel main table.
   If ambiguous, use the matching SDK kernel reader to inspect mainMethod.
5. Runtime proof must also pass: JUnit starts only its owned engine default main
   after installing fixtures/guards and receives successful finish from the
   paired scenario with exactly one native transfer and all transition checks.
   A wrong target must time out/fail. Never call the entrypoint verified before
   the APK exists and these checks actually run.

## Install, verify UID, then execute — only after separate review

Choose SERIAL explicitly and confirm ABI. Read installed packages first. Abort
if either isolated package already exists. Do not replace, clear or uninstall
pre-existing data, and do not open MainActivity.

Install the two verified APKs WITHOUT -r. Before starting any app process:

    rtk adb -s SERIAL shell dumpsys package org.musa.music.catalogintegration
    rtk adb -s SERIAL shell dumpsys package org.musa.music.catalogintegration.test
    rtk adb -s SERIAL shell cmd package list packages -U

Require no INTERNET requested/granted for either package and target UID shared
with no other package. Refuse execution if the package manager's installed state
does not agree with the inspected artifacts.

Only after all gates:

    rtk adb -s SERIAL shell am instrument -w -r -e class com.zarz.mornye.ProgressiveFlutterFinalFileInstrumentedTest org.musa.music.catalogintegration.test/androidx.test.runner.AndroidJUnitRunner

Save JUnit output/XML, Dart report, hashes and installed permission evidence.
No provider account, profile, external server or Flutter VM service is involved.

After own engine/player processes stop, uninstall ONLY the two exact packages
installed by this run and verify absence. This removes newly created prefs,
databases/cache/noBackup outside the fixture root without touching MUSA. Verify
MUSA's pre-existing package remains. No blanket clear/uninstall/force-stop or
connectivity commands are part of this plan.

## Remaining blockers

- Overlays, Kotlin and Dart have not been compiled/run. No APK permission or
  packaged-entrypoint result exists yet.
- The channel requires MainActivity. The harness attaches base Context by
  reflection to an unlaunched MainActivity solely for applicationInfo. If that
  fails, a separately reviewed Context injection is needed; do not silently
  start/reuse the application's cached engine.
- Headless binding/plugins, final-file seekability/position tolerance, and
  complete cleanup require instrumentation evidence.
- Dart observes the load Future immediately, propagates early failure during
  polling and attempts all cleanups independently with a 5-second bound. The
  original error is retained, with secondary cleanup failures. Timeout does NOT
  cancel an operation; it records unconfirmed cleanup and prevents success.
- HTTP refusal uses HttpOverrides.runZoned, without changing global overrides.
- finish now requires acknowledgeFinish after Dart receives the verdict reply.
  JUnit waits for this acknowledgement before destroying its owned engine. This
  proves receipt, not autonomous Dart isolate termination.
- Local Flutter static analysis checks this Dart source only. Neither analysis
  nor formatting validates native teardown, manifests, APKs or instrumentation.
- No production gate was enabled. The earlier 15 JVM passes do not validate
  this Flutter/Android scenario.


## Exact local APK inspection commands (prepared, not executed)

Verified local SDK executable path:
D:/Aplicaciones/Android-SDK/build-tools/36.0.0/aapt.exe
(aapt2.exe exists alongside it). Use aapt below, not an assumed PATH tool.

Before the build, capture the entry source hash and source-asset fingerprints;
the build must leave source assets and normal manifests unchanged. Its Flutter
asset bundle is a generated build output, not a permanent replacement in assets.

    $taskEntryHash = (Get-FileHash -LiteralPath $taskEntry -Algorithm SHA256).Hash
    $taskSourceRoots = @((Join-Path $taskRepo 'assets'), (Join-Path $taskRepo 'android/app/src/main/assets'))
    $taskAssetBefore = @($taskSourceRoots | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File } | Get-FileHash -Algorithm SHA256 | Sort-Object Path | ForEach-Object { $_.Path + ' ' + $_.Hash })
    $taskBuildStartedUtc = [DateTime]::UtcNow

Run the build command above only after review. Then, from repository root:

    $taskAppApk = Join-Path $taskRepo 'build/app/outputs/apk/debug/app-arm64-v8a-debug.apk'
    $taskTestApk = Join-Path $taskRepo 'build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk'
    $taskAapt = 'D:/Aplicaciones/Android-SDK/build-tools/36.0.0/aapt.exe'
    foreach ($taskApk in @($taskAppApk, $taskTestApk)) {
      $taskFile = Get-Item -LiteralPath $taskApk -ErrorAction Stop
      if ($taskFile.LastWriteTimeUtc -lt $taskBuildStartedUtc) { throw 'Old APK; provenance not established' }
      rtk $taskAapt dump badging $taskApk
      if ($LASTEXITCODE -ne 0) { throw 'aapt badging failed' }
      $taskPermissions = (rtk $taskAapt dump permissions $taskApk) -join [Environment]::NewLine
      if ($LASTEXITCODE -ne 0) { throw 'aapt permissions failed' }
      if ($taskPermissions.Contains('android.permission.INTERNET')) { throw 'INTERNET remains; do not install' }
      $taskManifest = (rtk $taskAapt dump xmltree $taskApk AndroidManifest.xml) -join [Environment]::NewLine
      if ($LASTEXITCODE -ne 0) { throw 'aapt manifest failed' }
      if ($taskManifest.Contains('android.permission.INTERNET') -or $taskManifest.Contains('sharedUserId')) { throw 'Manifest isolation failed' }
      $taskPermissions
      $taskManifest
      Get-FileHash -LiteralPath $taskApk -Algorithm SHA256
    }

Require exact package IDs in badging, and exact instrumentation targetPackage in
the test manifest. Save both dumps; do not approve based on no-INTERNET alone.

Kernel identity check without installation:

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $taskZip = [IO.Compression.ZipFile]::OpenRead($taskAppApk)
    try {
      $taskKernel = $taskZip.GetEntry('assets/flutter_assets/kernel_blob.bin')
      if ($null -eq $taskKernel) { throw 'Debug Dart kernel missing' }
      $taskInput = $taskKernel.Open()
      $taskMemory = [IO.MemoryStream]::new()
      try { $taskInput.CopyTo($taskMemory); $taskBytes = $taskMemory.ToArray() }
      finally { $taskInput.Dispose(); $taskMemory.Dispose() }
      $taskKernelText = [Text.Encoding]::UTF8.GetString($taskBytes)
      foreach ($taskMarker in @('musa.test/progressive_final_file','android_progressive_final_file_test.dart','Native paired instrumentation harness is absent')) {
        if (-not $taskKernelText.Contains($taskMarker)) { throw ('Wrong or ambiguous Dart target: ' + $taskMarker) }
      }
      $taskSha = [Security.Cryptography.SHA256]::Create()
      try { [Convert]::ToHexString($taskSha.ComputeHash($taskBytes)) }
      finally { $taskSha.Dispose() }
    } finally { $taskZip.Dispose() }
    if ((Get-FileHash -LiteralPath $taskEntry -Algorithm SHA256).Hash -ne $taskEntryHash) { throw 'Dart source changed during build' }
    $taskAssetAfter = @($taskSourceRoots | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File } | Get-FileHash -Algorithm SHA256 | Sort-Object Path | ForEach-Object { $_.Path + ' ' + $_.Hash })
    if (Compare-Object $taskAssetBefore $taskAssetAfter) { throw 'Source assets changed; stop for review' }

These commands stop at build/inspection. They install nothing. The kernel marker
check remains a necessary identity check, not an executed entrypoint/main proof.
If AGP produces different output names or cached output older than the recorded
build start, stop and establish artifact provenance instead of guessing.

## Source-only Application candidate after the first failed instrumentation

The archived APKs in offline-build-01 still use MornyeApplication. They DO NOT
contain this new candidate and must not be replayed as if they did.

The test-only debug overlay now selects android.app.Application and removes
androidx.startup.InitializationProvider. This avoids the custom crash reporter
and automatic WorkManager/other Startup initialization; production files remain
unchanged. The instrumentation requires the base Application and still refuses
every pref/data entry. Enumeration failure now fails closed. Diagnostics contain
only entry names/types/counts, never preference contents or values.

Static XML/source checks passed; no new build or device run was performed.
A future build MUST additionally verify base Application and absence of the
Startup provider in the merged APK manifest. INTERNET/UID gates still apply.

The handler/deck/channel route does not call runtime.initialize/AudioService.init
and does not use the cached-engine configurator/resource resolver installed by
MornyeApplication. This is source-level dependency evidence, not runtime proof.
An independent unresolved limit remains: real Android audio focus can be denied
to this headless engine without a foreground service on Android 15+. The injected
synchronizePlaybackState callback is a no-op. Do not claim the route functional
until this focus condition is resolved or explicitly scoped by separate review.


## Diagnostic revision after offline-build-02 crash (not built or run)

The only observed 02 result is `Process crashed.`; its raw instrumentation output
has no terminal JUnit result or Dart verdict. No cause or last completed harness
operation can be inferred. Preserve the archived 01/02 logs and APKs unchanged.

New native markers use only closed HarnessStage enum names in the
MusaHarnessStage log tag and musa_harness_stage instrumentation status bundle
(code 2, diagnostic and nonterminal). Dart emits closed _HarnessStage names with
MUSA_HARNESS_STAGE. A BEGIN marker proves entry only; END proves that operation
returned. Markers introduce timing overhead and are not a substitute for results.
No arguments, paths, exception text, preferences or user state are added to these
markers. Existing test assertions and runtime gates remain unchanged.

Before any separately authorized future run, prepare a bounded host supervisor:

1. Recheck both APK hashes/manifests and fresh isolated package/UID ownership.
   Derive the new target UID from package inventory; never reuse a historical UID.
2. Before instrumentation, read device clock for a logcat start boundary and
   start a reader with `adb -s SERIAL logcat --uid=TARGET_UID -T DEVICE_TIME
   -v threadtime`. Confirm reader startup or abort the run and clean own installs.
   Do not clear logcat, change buffers, or read unrestricted device logs.
3. Filter IN MEMORY before writing: retain only exact closed native/Dart stage
   names plus crash category (FATAL_EXCEPTION, FATAL_SIGNAL, PROCESS_DIED) and
   Java exception class/native signal number. Do not persist raw crash message,
   stack text, paths, arbitrary Flutter output or other application data. Keep
   counts of rejected lines only. Unknown formats are dropped; missing crash
   details remain an explicit limitation, never justification for broad capture.
4. Run the single specified instrument command with its 150-second host timeout.
   Filter instrumentation output in memory as well: retain only numeric status/result codes, exact test identity and closed enum stages. Drop arbitrary result payloads, filenames, errors and stacks; retain the fixed Process crashed category only. Do not persist raw am output for this revision or interpret status code 2 as pass.
   On completion/crash/timeout, drain UID capture for at most 2 seconds WHILE
   packages are still installed. Stop only this reader, cap capture at 256 KiB,
   save the sanitized file to the new evidence directory, and hash it with the
   sanitized instrumentation result. Capture failure must be recorded, not retried.
5. Only AFTER capture has been closed and saved, uninstall exclusively the two
   packages installed for that run; verify absence, original MUSA UID and no
   harness processes. Cleanup runs even when capture or instrumentation fails.

The capture_uid_logcat.py helper is implemented but not executed; it owns only the UID reader. Its syntax was checked with ast.parse. The outer instrumentation/cleanup supervisor still requires review and integration before use;
no adb command above has been executed for this revision. UID filtering does not
capture system-process tombstones and an early process death may precede the
first marker. Do not infer absence of a crash from an empty sanitized capture.
No new build, device operation or production change is part of this diagnostic
revision. Dart Future timeouts still do not cancel underlying work.


The UID helper accepts --adb, --serial, --uid, --device-time, --output (NEW
exclusive directory), --stop-file (absent until the caller requests drain), and
--seconds (at most 180). It publishes ready only after reader survives startup;
the caller must abort if readiness is absent or the helper exits. After the
instrumentation process has ended, create the stop-file and wait for helper exit
and summary.json BEFORE uninstall. It terminates/kills only its own reader.
A ready file confirms a live reader, not successful log delivery. The helper
never installs, instruments, uninstalls, clears logs, or changes buffers. All
markers across threads are observations, not a total causal ordering. A complete
outer supervisor is still pending; do not execute this incomplete protocol.


Outer supervisor source: instrument_once.py. It accepts the same explicit adb,
serial, UID, device-time and fresh output arguments, starts UID capture, requires
readiness, invokes exactly the fixed instrumentation class once (150 s), and
persists only sanitized status codes/enum/crash category. It waits for UID capture
persistence before returning. It performs NO installation or uninstallation;
the authorized caller must inspect supervisor.json and perform package cleanup
in its own finally block after supervisor exit, even on failure. Unknown payloads
are discarded. UID read failures make evidence incomplete. Host-only unittest
covers secret rejection, child crash and timeout cleanup; Android/ADB behavior
is untested. Review required before execution. Earlier statement that outer
supervisor is pending is superseded by this source-only implementation.


Review corrections: success requires exactly one case STATUS_CODE 0, no negative
case status, and final INSTRUMENTATION_CODE -1; adb exit0 alone is insufficient.
Crash/incomplete/error outputs fail. Both streams read bounded chunks and drop
lines exceeding4096 characters. Java exceptions retain only JAVA_EXCEPTION,
never a dynamic class name. UID/serial ownership is verified by the caller;
ready proves only a live reader, not functional log delivery. No device claim.


Loss is fail-closed: recognized-event queue overflow, output byte-cap overflow,
or oversized input line sets persistent loss in evidence and forbids passed.
UID capture likewise records loss/line_truncated and returns failure on loss.
Discarding intentionally unrecognized/private payload is filtering, not evidence
that the original stream was complete. Saturation is tested with a simulated
queue.Full dropping a failure followed by otherwise-successful terminal codes.


Epoch correction (Python-only revision): --device-time MUST be numeric epoch.mmm
with exactly three fractional digits, e.g. device `date +%s` plus `.000`. Both
supervisors reject missing fraction and calendar formats BEFORE spawning adb.
Acquire the value immediately before the reader and reverify UID ownership.
Reader stderr is consumed in bounded chunks and only fixed categories persist;
raw stderr is never saved. Nonempty/classified/truncated stderr fails capture.
The earlier03 reader failure matched unsupported TIME without milliseconds;
no instrumented test ran in that attempt. New Python revision is not device-run.


Reader exception correction: all three reader threads catch exceptions without
retaining their text, set fixed reader_error/stderr_reader_error plus loss, and
fail closed even when thread joins normally. Offline fault injection raises an
exception containing a synthetic secret in instrument stdout and both UID
streams, verifies failure and confirms that secret never appears in evidence.


Post-SIG11 marker revision (source-only): adds RESULT_CALLBACK_BEGIN/END,
resultEventReceived, hash/store put/acquire begin/end, setFileSource begin/end,
FINAL_PREPARED_OBSERVED and FINAL_EQ_ENABLED_OBSERVED, and fixture lease/session
close begin/end. Observed prepared/EQ flags are snapshots, not brackets around
native API calls. Fixture close END does NOT prove Media3 renderer release has
finished; productive release internals remain intentionally unmodified.

Signal11 metadata plan: only a future separately authorized capture may retain
own PID/TID and allowlisted module BASENAME + numeric relative PC offsets, after
matching the crashing PID to the isolated package process from that run. Strip
paths and reject unknown modules/lines before disk. Current UID filter does not
retain tombstone frames; debuggerd/system-process logs lie outside UID capture.
No access to restricted /data/tombstones is established and no global logcat or
memory dump is authorized. Thus current evidence cannot identify module/offset.
Do not broaden capture or attribute SIG11 to Rust, Flutter, SQLite, MediaPlayer,
EQ or fixture I/O without corroborating crash metadata.


Optional own-frame parser (Python-only; no APK/device change): UID helper accepts
at most8 explicit --own-pid values verified independently by the caller against
that isolated UID. Never derive allowlisted PID from crash payload. Default is
empty, so no frame retention. Only standard threadtime F/E DEBUG #NN pc frames
EMITTED BY an allowlisted own PID may retain a fixed library basename allowlist
plus numeric module-relative PC (<=32bits). Full paths, symbols, process/thread
identifiers, register/absolute addresses, memory and arbitrary messages are never
persisted by this parser; oversized/malformed/unknown libraries are rejected.

Existing outer supervisor does NOT pass own PIDs; enabling requires separate
reviewed ownership discovery before capture. Many Android tombstones are emitted
by debuggerd under system UID/PID, outside this filter: they must remain dropped,
not justify broad logcat. Empty capture cannot establish absence of native crash
or prove module identity. This parser has only offline synthetic-string tests.


Ownership clarification: --own-pid is caller-supplied, NOT verified by the reader.
Before any future enabling, external gates must match UID/package/PID AND process
start-time to this run, restrict capture to that lifetime, and detect exit/reuse;
a historical/recycled PID must not be trusted. The current supervisor implements
none of these additional gates and passes no own PID, so this feature remains
DISABLED. A regex-accepted #pc frame only matches the allowed syntax/emitter; it
does not prove association with this crash or identify a crashing thread/module.
System-UID debuggerd tombstones remain outside scope. Do not infer verified
ownership or crash provenance from a permitted frame. No device action authorized
by this documentation update; no product code changes.
