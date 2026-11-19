# Isolated Android panel fixture overlay

Prepared assets only; this folder is outside active Android source sets. No build, server, certificate generation, device installation or device trust change has been performed.

## Apply in a disposable snapshot

1. Start from the agreed candidate snapshot. Copy the five panel product files from the parent handoff exactly, preserving existing candidate changes. The panel changes do not modify Rust or pubspec dependencies.
2. Append `verificationFixture.gradle.kts.fragment` to that snapshot's `android/app/build.gradle.kts`. Copy this folder's `AndroidManifest.xml`, `java/` and `res/` into `android/app/src/verificationFixture/`. Do not put these files in `src/main` or `src/debug`.
3. Run `generate_fixture_tls.ps1` with a new, absolute output directory outside the checkout. It requires Git OpenSSL. It creates a two-day fixture CA and a localhost leaf; private keys remain in the external directory. Copy ONLY `musa_fixture_ca.pem` into snapshot `src/verificationFixture/res/raw/musa_fixture_ca.pem`. Never copy `*.key` into any source/artifact directory.
4. Inspect merged manifest/package before installing: exact package `org.musa.music.verificationfixture`, nonexported host/panel, debuggable, fixture-only network config. Check that release and ordinary debug source sets do not reference fixture CA/host/config. The custom Flutter build type has not been configured or built yet; if unsupported, use a separate disposable snapshot's debug source set with the same unique package suffix, never the user's normal debug package.
5. Build only after explicit task authorization. `MUSA_EMBEDDED_VERIFICATION=true` is required for the Dart pending-auth path, but the native host opens the panel directly and does not require this Dart flag. Keep production default false. Native host uses the real panel and navigation policy; its return boolean is presentation completion, never authentication success.

## TLS and synthetic backend boundary

The variant embeds only a CA public certificate for `localhost`, preserving system anchors elsewhere and refusing cleartext. This is a scoped Android Network Security Configuration, not `SslErrorHandler.proceed`, a device CA installation, or a network egress sandbox. [Android's official documentation](https://developer.android.com/privacy-and-security/security-config) describes raw resource CAs and per-domain trust.

No certificate/private key is prepared by this repository. Only the isolated APK trusts the generated CA; the S24 system/browser trust is unchanged. Do not add the CA to production resources. Use `adb reverse` only for ports 9443 and 9444, run the server bound to 127.0.0.1, and record reverse mappings owned by this test before creating them.

`VerificationFixtureHostActivity` is a test-only target Activity using a local in-process BinaryMessenger to invoke the existing panel coordinator with a fixed URL. It requires instrumentation to start because it is not exported. It adds no production URL override. It does not install provider extensions or mint a valid backend state/grant. The real MainActivity/backend still receives candidate callbacks and must reject the synthetic invalid grant. Full successful redemption/replay tests require a backend fixture which creates a legitimate one-time test pending state; the UI host alone cannot establish them.

## Instrumentation and evidence

Use `InstrumentationRegistry.getInstrumentation().startActivitySync(Intent(targetContext, VerificationFixtureHostActivity::class.java).addFlags(FLAG_ACTIVITY_NEW_TASK))` from a test targeting the isolated package. The host is inside the test variant target APK; do not place it solely inside the test APK. Record only case IDs, outcomes, package/version/WebView version and synthetic counters. Do not dump app prefs, cookies, session URLs, logcat wholesale or real credentials.

Run the matrix in `../verification_panel_device_plan.md`: expected/foreign state, direct POST, POST 307/308, GET redirects, visible origin/403, timeout, rotation and process death. Observe the foreign server's POST counter independently of what the WebView displays. A page being hidden after a POST is a failed containment test. Rotation explicitly offers Retry; it is not proof that a one-time provider URL can be reused.

Before capturing screenshots, note the production panel uses `FLAG_SECURE`. Do not remove it from production for screenshots; use human visual inspection or an explicit test-only capture policy and label those captures as fixture UI.

## Cleanup (only resources created by this run)

Stop the fixture server; remove only test-owned reverse mappings; uninstall only `org.musa.music.verificationfixture` and its associated instrumentation APK. Delete the ephemeral TLS directory only after resolving and checking its exact absolute path. Remove the disposable build snapshot or fixture-only overlay after preserving non-sensitive case outcomes. Do not uninstall/clear `org.musa.music`, `org.musa.music.debug`, or catalog integration packages; do not change S24 CA trust, accounts, downloads or app settings.
