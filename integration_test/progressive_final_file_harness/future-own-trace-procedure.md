# Future collector trial — PROCEDURE ONLY, NOT EXECUTED

Do not use the S24 while the user is using Google Play. This document authorizes
no device interaction. Six existing build09 Kotlin test methods passed on local
JDK25 via a fixed reflection runner and their original compiled bytecode/JUnit
assertions (no source transplant/mirror). AndroidJUnit4 and ApplicationExitInfo
API were NOT exercised; trace availability/OEM format/nonce binding unproven.
Evidence: offline-build-09/local-parser-jvm-01, result.txt, execution.json,
local-parser-derived.xml, evidence-hashes.json.

After separate permission to take the device:
1. Recheck exact archived build09 APK hashes/manifests/signatures/fixture IDs.
   Recheck awake/volume0 and absence of BOTH isolated technical package IDs.
   Inventory MUSA and installed Poweramp package identities/UIDs (resolve actual
   package names from inventory; never assume or read their app data). Record
   metadata-only baseline. Do not launch/stop/change/uninstall those packages.
2. Install only org.musa.music.catalogintegration and its .test APK without-r.
   Verify each UID exclusive and both noINET/sharedUID, MUSA/Poweramp UID unchanged.
   Any failed gate => cleanup ONLY packages installed in this trial; no test.
3. Get fresh device date+%s, append .000. Invoke reviewed instrument_once.py once
   with --scenario progressive --correlate-own-crash, explicit adb/serial/UID,
   fresh output directory, and outer caller timeout>=210s. Do not echo argv/raw
   instrumentation or persist nonce. Supervisor generates128bit nonce internally.
4. If no crash, do not manufacture one or rerun: collector is not called. If
   confirmed own crash occurs, supervisor first drains/saves sanitized UID trace,
   then makes a single fixed collector invocation. It keeps UID/PID/start and
   nonce privately in memory. Collector gates own real/packageUID, exact process,
   PID, epoch window/recency and processStateSummary nonce BEFORE opening trace,
   then validates tombstone UID/PID and crashing-thread key. Null/overwritten,
   malformed/noncanonical/oversize/timeout trace fails closed. No raw protobuf,
   memory, registers, paths, symbols or other-thread data reaches disk.
5. Persist only sanitized runner/UID/own-trace outputs and hashes BEFORE uninstall.
   A TRACE_SIGNAL plus permitted module@relativePC is a backtrace projection,
   not causal proof. Original crash stays failed even if collector succeeds.
6. In caller finally, after supervisor/reader/collector completion, uninstall
   exclusively the two packages installed in this trial; verify absence and zero
   own processes. Recheck MUSA AND Poweramp package/UID baselines unchanged.
   Never alter connectivity, other packages, media settings beyond authorized
   silence, or app data. Do not retry after failed gate/crash/trace-unavailable.

Safety limits: nonce/IDs exist transiently in adb/am argv to authorized OS
observers; privacy is not absolute. Trace read/close can block beyond3s, leaving
cleanup unconfirmed despite bounded caller failure. Parent host timeout must
terminate only its own child tree if needed; collector must never run after the
technical package uninstall. If supervision cannot prove reader/collector exit,
report failure and retain that limitation; do not claim verified cleanup merely
because threads are daemon. MUSA/Poweramp must never be targets of force-stop,
uninstall, data clearing or permission changes.
