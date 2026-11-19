# Original-song MediaPlayer/EQ matrix — SOURCE ONLY

The new Android test uses Carefree by Kevin MacLeod, original official MP3 bytes
SHA2568433b770a630d9b1594fd484442c677907ece899a4d149954cd2e74fd733e311.
Provenance and attribution accompany the androidTest asset. No transcoding.
This is downloadable CC-BY music, not a streaming-service-provider integration;
MP3 differs from the earlier fragmented AAC fixture and cannot vindicate it.

Two cases selected together by the explicit real-song class allowlist:
- RealSongMediaPlayerEqInstrumentedTest#originalMp3MediaPlayerWithoutEq
- RealSongMediaPlayerEqInstrumentedTest#originalMp3MediaPlayerWithProductiveEq

Both use real MediaPlayer, require system stream0 and additionally player gain0,
prepare original file, seek1s, verify advancing playback for500ms while muted,
pause, close effects and release player/thread/own temporary file. On case uses
the actual PlaybackEqualizer class via test-only reflection, balance0.25 and flat
10bands before prepareAsync, matching the relevant effect timing. No gate or
productive source changes. Native crash can bypass JUnit finally; host must still
capture sanitized own-process evidence and uninstall only its installed packages.

Interpretation: off-fail implicates baseline MP3/MediaPlayer/environment; off-pass
and on-fail narrows to added effect/configuration/timing; both-pass leaves AAC,
retirement interaction, Flutter and other differences unresolved. Signal11 alone
never proves causality. This does not run WrappedPlayer/MixedOutput/Flutter or
retirement, and cannot claim the original transition fixed.

NOT BUILT, NOT RUN. instrument_once.py now supports --scenario real-song with a fixed class
allowlist and requires EXACTLY two successful case completions plus runner final
code-1; it captures closed MusaRealSongStage names. Before execution, review
offline APK permissions/identity, both fresh UID ownership and muted volume.
Exact licensed asset hash must be inspected in the built test APK. No conversion
or replacement of productive assets is authorized by this test.


Cleanup revision: stage transport cannot throw. Root creation and thread startup
are within try/finally. onLoop timeout revokes queued Runnable and removes it;
a currently executing native call is not cancellable. Cleanup and thread join
remain bounded; if thread survives, test fails and does not claim cleanup or
delete files potentially still in use. Host removal of isolated packages remains
required after capture, including native crash. This has not been Android-built.


Final supervisor selection supersedes the class-wide two-case proposal:
--scenario real-song-off and --scenario real-song-on map to fixed Class#method
values above, each requiring exactly ONE successful case and finalCODE-1.
Use separate fresh output directories and separately authorized isolated runs;
a crash in one process cannot be counted as a result for the other. Never rerun
a crashed case automatically. Compare only actual independent results. No free
class/method argument is accepted; previous --scenario real-song is rejected.


AAC isolation extension (source-only, not built/run): two additional fixed method
scenarios synthetic-aac-off/on use the EXACT existing fragmented AAC asset
synthetic_fragmented_aac_test.m4a with SHA256
6ce40162ece699baf60e7f752f4f0ed76e1f7a6f129dd0bf705419b95fd2fd58.
No transcoding, Flutter, retirement or productive source change. Same MediaPlayer
and effect settings/lifecycle as MP3; duration floor2s accommodates synthetic
clip, with the same seek1s +500ms advancing muted playback requirement. Each
scenario maps to one fixed method and requires exactly one successful result.
Compare to the recorded MP3off/on passes without asserting formats equivalent.
AAC failure with MP3 pass would narrow codec/container vs environment interaction;
AAC passes still cannot exclude the original transition-specific SIG11.
