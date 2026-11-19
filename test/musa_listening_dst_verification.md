# Native DST verification status (2026-11-06)

The native Dart versus Rust DST comparison remains **unverified** on this host.
No Windows system time zone, WSL installation/configuration, or production
listening implementation was changed for this check.

Executed from the application root:

```text
rtk cargo test --manifest-path rust_backend/crates/musa-listening/Cargo.toml --test shared_dst_vectors
1 passed

rtk D:\Aplicaciones\flutter-3.47.8\bin\flutter.bat test test/musa_listening_dst_test.dart test/musa_listening_shared_dst_vectors_test.dart
0 passed; 2 skipped
```

Rust's passing test uses injected New York midnight instants. Its shared fixture
covers the 23-hour spring day, 25-hour autumn day, spring midnight crossings, and
the repeated autumn hour. This validates Rust accounting against those expected
boundaries; it does not validate the Dart native local calendar.

Both Flutter tests deliberately skip unless the process reports
`TZ=America/New_York` **and** native `DateTime` offsets match both 2026 transitions.
An all-skipped exit code is not a DST parity pass.

Ubuntu WSL2 was already running. Read-only inspection found no `dart` or `flutter`
on its login PATH, and no Dart/Flutter executable or cached Linux SDK archive in
`/home/roga9`, `/opt`, `/usr/local`, or `/tmp` to depth five. This is a bounded
inventory, not proof that no Linux SDK exists anywhere. The inspected installed
SDK at `D:\Aplicaciones\flutter-3.47.8` is the Windows SDK.

The existing `now` injection cannot replace the production recorder's native
`DateTime(year, month, day + 1)` midnight constructor. A test-only fake clock or
an injected Rust calendar therefore cannot establish native Dart DST parity on
this host. No extracted copy, JavaScript backend, or substituted algorithm was
used as evidence.

To close the remaining check, run both existing Flutter test files with an
already available Linux Flutter SDK in an isolated process using
`TZ=America/New_York`. Require **2 passed, 0 skipped** and the shared Rust fixture
test passing. The tests verify the expected historical offsets before executing.
