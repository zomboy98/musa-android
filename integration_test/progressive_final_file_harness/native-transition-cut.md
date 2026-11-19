# Native transition cut — NOT BUILT OR RUN

NativeMedia3FinalWrapperInstrumentedTest has two fixed methods selected by
native-transition-off/on (one case each). Uses exact fragmented AAC SHA256
6ce40162ece699baf60e7f752f4f0ed76e1f7a6f129dd0bf705419b95fd2fd58,
with last1024bytes withheld while the REAL Media3ProgressivePlayer renders via
WrappedPlayer. It advances muted to>=600ms, pauses, captures/stabilizes position,
sets balance0.25 through the real setter, waits for the actual deck close callback
and lease revocation/source null, then applies EQ off/on and writes identical
full bytes to own file. Real UrlSource creates MediaPlayerWrapper including
MixedOutput and productive PlaybackEqualizer. Requires prepared state, actual
seek-completion event, paused position stability, explicit muted resume advancing
>=300ms and pause, then bounded disposal. No optimistic position-only seek pass.

Plugin fields/constructor are wired using existing instrumentation patterns;
public debug-only per-instance capability admission remains enforced. No engine,
Dart, SQLite, Rust owner/producer, MethodChannel or production coordinator is run.
EventSink observes actual player events; it does not manufacture prepared/seek.
Audio focus acquisition is disabled identically in both cases, while system
volume0 and player gain0 are required. This differs from integrated Flutter focus.

Compare against existing AAC MediaPlayer direct off/on passes: failure here
would narrow native wrapper/MixedOutput/retirement interaction, not prove a
specific native module. Passing here leaves Flutter/controller/store/timing and
other differences unresolved. Full native disposal completion below the actual
deck callback is not independently proven. No global causal ordering of markers.

No EQ timer/listener duplication in this native cut: one real setter config after
retirement in each variant. This is intentionally different from the integrated
listener comparison. All stage identifiers fixed; helper/supervisor allowlists
were extended, own-frame optional capture remains disabled.19 offline host tests
pass, but Kotlin signatures/build/runtime need independent review before any
single offline build or S24 run. Existing APK07 does not contain this test.

Cleanup: queued task timeout revokes/removes that task; a running native call is
not cancellable. Cleanup waits bounded close and worker join, failing if still
alive and refusing to claim confirmed cleanup. Native crash bypasses finally;
host must preserve sanitized evidence before removing only its isolated packages.
