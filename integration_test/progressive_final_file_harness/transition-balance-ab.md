# Balance-trigger transition A/B — source-only

Fixed scenarios transition-eq-off/on select one native test method each. Both
reuse the SAME Dart entrypoint, AAC bytes/lease/producer barrier, early playback,
pause position, catalog hash/store path, source loading and final assertions.
The original progressive scenario remains its original fixed method.

Both variants begin with EQ disabled and invoke actual audioplayers setBalance
0.25 on music-player; only this balance command requests retirement. They await
native command reply, leaseClosed and engine==null, then verify EQ still false
and balance0.25. Thus EQ cannot be the initial retirement trigger in these cases.
Only after this barrier, both send actual setEqualizer with identical flatband
configuration/balance, differing only enabled=false/true, await reply and a
snapshot confirming the requested setting while engine remains null, THEN
release the producer. Same final pause/position/no-spurious-resume assertions
are retained; expected final EQ flag follows variant.

This guarantees test-observed command/barrier order, not identical wall-clock
or native thread timing. The existing EQ listener has its32ms timer and can
send another equivalent configuration (on/off paths differ internally);
DynamicsProcessing native work and Media3 release may continue asynchronously.
Fixture lease closure and engine null do not prove all Exo native release work
finished. No causal order inferred across debugPrint/producer/main threads.

A difference would narrow the added post-retirement EQ path, not prove a specific
JNI/module fault. Both failing would leave final load/seek/MixedOutput/retirement
interaction plausible; both passing would not invalidate earlier SIG11.

No product changes, gate activation, build or device run. Flutter analysis passes;
17 host-only supervisor tests pass, including fixed method selection and rejecting
failure/incomplete/extra-case statuses. Kotlin compilation/runtime remains pending
independent review. Existing APK06 does not contain this revision; do not run it
as if it did. Future build must verify fixture selector strings and Dart markers.


Strict comparison limit after review: preserving the real EQ listener means the
full EQ command sequence cannot be matched. `_syncEqualizer` skips disabled EQ
when no earlier EQ was sent; enabled EQ sends after its32ms timer, in addition
to the explicit acknowledged command. That duplicate may precede or follow the
explicit command. There is no public Future for the listener to settle. Both
cases guarantee same BALANCE retirement trigger and retirement barrier before
any EQ variant, but compare post-retirement EQ STATE PLUS listener/send timing,
not a pure DSP-enabled bit experiment. Do not attribute a result solely to DSP.
