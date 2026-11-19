# Own ApplicationExitInfo diagnostic — NOT BUILT / NOT RUN

Official API reference:
https://developer.android.com/reference/android/app/ApplicationExitInfo#getTraceInputStream()
API31+ REASON_CRASH_NATIVE trace is protobuf; it can be null or overwritten.
Schema pinned to AOSP tombstone.proto blob9deeeec9e185f79747acf5fb6a7e71586eb7da16:
https://android.googlesource.com/platform/system/core/+/refs/heads/main/debuggerd/proto/tombstone.proto
Blob above records the reviewed content identity; main may evolve.

Three new test-only Kotlin files prepare collector, streaming projection and4
synthetic parser cases. No new protobuf/runtime dependency or production change.
Collector only accepts isolated package/baseApplication/current matchingUID and
externally recorded exact oldPID/device epoch window<=180s, queried within60s.
Only one own process-name/realUID/packageUID/PID/time/native-reason match allowed.
Additional REQUIRED per-run128bit nonce must match ApplicationExitInfo process
state summary byte-for-byte (MUSA_TEST_TRACE:<32lowerhex>). This binding prevents
selecting another same-UID/PID historical record. No trace is opened before gates.

IMPORTANT BLOCKER: the crash harness does NOT currently call
ActivityManager.setProcessStateSummary with that nonce. It must be separately
reviewed/wired test-only BEFORE reproducing any new crash; no hook was added here.
Thus existing crashes cannot satisfy this collector, which fails closed. The
supervisor also has no collector scenario/output parser. Do NOT run or claim
this facility operational. Host must establish fresh UID ownership/process PID,
time bounds and nonce; do not guess them or search arbitrary history/traces.

Streaming parser validates top-level protobuf UID/PID again and uses only the
crashingTID thread map. It skips registers/memory/abort/log/otherthread values;
returns only signal1..64 and max64 fixed-library-basename+relativePC<=32bit
frames. Symbols/paths/IDs/timestamps never leave collector. No raw file/cache or
protobuf persistence. Unknown ordering/schema/malformed lengths/duplicate owner
or crashingthread/truncation/missing trace cause rejection, never inference.

Limits:8MiB read budget, max256 examined crashing frames, max512byte path field,
3s parser deadline; caller wait3.5s plus100msjoin. Blocking framework read/close
may not be cancellable; timeout returns failure with cleanup UNCONFIRMED and
never emits late worker output. Host must still remove own packages after
sanitized evidence; daemon threads are not proof of resource disposal.
A collected module/frame would locate a backtrace, not prove root cause.

Synthetic cases (PREPARED ONLY, not executed due no execution/build instruction):
secret memory/log/register/path/symbol fields and other-thread frames are absent
from projection; wrongUID/PID/oversizeoffset rejected; unknownmodule omitted;
byte/deadline/truncation/duplicate/noncanonicalidentity rejected. Android source
has not compiled; correctness and OEM schema/API behavior remain unverified.


Review correction: a frame is emitted only when rel_pc field1 was explicitly
observed. Proto3 can omit a numeric zero; absence is therefore unavailable data,
not an observed offset0, and that frame is omitted. An explicit encoded0 remains
valid. A fifth synthetic test covers missing vs explicitzero. These Kotlin tests
remain uncompiled/unexecuted; no passing claim or new device/build operation.


Nonce/supervisor connection revision (SOURCE ONLY, supersedes blocker above):
TestOwnCrashCorrelation.bindIfRequested is called by the integrated harness before
scenario setup. Absent diagNonce returns with NO side effects/metadata. A valid
128bit lowerhex value is validated in the isolated debug/baseApplication process
and set as processStateSummary before the phase. Only own numeric UID/PID/start
fields are sent privately to the supervisor; nonce itself is never emitted.

Supervisor --correlate-own-crash is OFF by default, permitted only for the fixed
integrated scenarios. When explicitly enabled it generates secrets.token_hex(16)
in memory, passes it to the test and consumes own-run metadata without writing
those fields/nonce to output. A confirmed crash (no loss/timeout/reader error,
UID match/start bound) triggers exactly ONE fixed collector method, only AFTER
original UID capture has drained and persisted. Device epoch-end is bracketed
by two bounded date reads with a distinct second; collector rechecks the<=180s
window and<=60s recency, own identity, exact nonce and protobuf UID/PID. No trace
is opened if binding is absent/ambiguous. It saves only sanitized fixed signal,
module allowlist and relativePC; original crash remains FAILED even if retrieval
succeeds. Null/unavailable trace is diagnostic failure, not a crash explanation.

This is not yet built/device-validated. Caller must keep packages installed until
supervisor exits and always uninstall only its own packages afterwards. Host
outer timeout must allow original150s plus reader drain and follow-up collector
(clock<=12s + collector15s); budget>=210s recommended. Do not reuse old185s wrapper
for this opt-in. Default runs without the flag retain the original behavior.
Nonce is an ephemeral correlation token, not persisted evidence or a credential;
argv exists transiently while adb executes, so no public/raw argv logging allowed.

22 Python offline tests pass, including private metadata/noncepayload exclusion,
fixed collector command/window rejection and sanitized trace signal/module filters.
Six Kotlin synthetic tests are prepared (five parser + nonce checks) but NOT
compiled/executed. No build/device/production change in this revision. External
fresh-package/UID gates and independent review remain required before use.


Safe crashing-thread counters revision (SOURCE ONLY; no new trace/build/device):
total frames; named/missingName; allowed/unallowed(named only); PCpresent/missing;
emitted; unknownFields. Counts are numeric only and limited to256 (unknownFields
1024); reaching a hard parser limit rejects the projection. Sensitive KNOWN
fields are skipped and NOT classified as unknown. Unknown field numbers/values
or strings are not emitted. Only crashTID Thread and its BacktraceFrame messages
contribute; other-thread frames/unknown fields contribute NOTHING.

Schema mapping independently checked against official AOSP source above:
Tombstone pid5/tid6/uid7/signal10/threads16; Thread id1/current_backtrace4;
BacktraceFrame rel_pc1/file_name6, known fields1..8; Thread known fields1..9.
The pinned blob records reviewed schema; OEM differences may still reject or
manifest as unknown counts. No allowlist expansion made.

One new synthetic Kotlin case covers allowed/unallowed/missingname/missingPC,
crashing-thread unknowns and ignored other-thread fields, plus zero-frame thread.
It is NOT compiled/executed; earlier six-class JVM pass was before this revision
and does not validate new counters.23 host Python tests now pass (1.493s), including
fixed-key/range sanitization. Collector success09 emitted signal11 and zero
frames, but these new counters were absent then; reasons cannot be reconstructed
without a separately authorized new own trace because no raw trace was saved.


Completeness revision: own-trace summary separates signal_valid from
counters_complete. Complete requires all9 count keys EXACTLY once, numeric bounds,
total=named+missingName=PCpresent+PCmissing, named=allowed+unallowed,
emitted<=allowed/PCpresent, and actual sanitized frame-line count=emitted.
Missing/duplicate/inconsistent counts forbid passed diagnostic completeness;
a valid signal alone is partial evidence. Prior09 signal-only evidence remains
signal-only; do not retrofit counters or reinterpret old collector pass as complete.
unknownFields counts only fields outside known numeric ranges in crash thread/
frames; zero is NOT a compatibility audit or proof the OEM schema matches AOSP.
