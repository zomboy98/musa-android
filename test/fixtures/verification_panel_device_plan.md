# Embedded verification candidate: device gate

Default `MUSA_EMBEDDED_VERIFICATION=false` remains mandatory until these checks pass. Synthetic tests do not establish that a real provider permits WebView. Do not use production grants, sessions or accounts in this fixture.

## Infrastructure

`verification_https_server.py` creates two loopback-only HTTPS listeners on 9443 and 9444, accepts a certificate/key supplied with `--cert`/`--key`, and never logs queries, bodies or headers. It prints only synthetic POST counts on shutdown. Start URL: `https://localhost:9443/verify?state=musa-fixture-state`.

The app correctly rejects an untrusted certificate. A valid test therefore needs a disposable emulator with a properly trusted test CA, or a controlled HTTPS host with a certificate already trusted by Android and two distinct origins. Do not bypass `onReceivedSslError`, weaken app trust, install a CA on the user's S24, or start a public tunnel implicitly. `adb reverse tcp:9443 tcp:9443` and 9444 can connect an authorized disposable emulator to the loopback fixture, but do not solve certificate trust.

The current pending-auth bridge needs an isolated fixture backend returning the synthetic auth URL. There is deliberately no production URL override or exported Activity added for testing. A fixture backend/authorized test harness is required to open the full pending-auth flow. The static native compilation and policy tests do not replace this integration harness.

## Required instrumented cases

1. Opt-in candidate shows MUSA panel; browser remains closed until explicit fallback. Activate loads fixture. Cancel/back and the existing three-minute deadline close only that request. Already-authenticated backend shows no panel.
2. Try direct cross-origin POST and same-origin POST followed by 307/308. Foreign-origin POST counter must stay zero if claiming network containment; if it increases, stop promotion and use a browser-based trusted verification workflow or a provider-approved origin design. Hiding/stopping a page after transmission does not satisfy containment.
3. Try GET 307/308, mixed HTTP, custom schemes and renderable HTTP403. Show true visible origin; blocked targets must not display trusted-origin labeling. 403 content must remain visible.
4. Tap foreign-state callback: panel stays open, no grant succeeds. Matching synthetic state can reach the existing native/backend validator, which must reject the invalid grant. Replay after completion and after a new attempt must not grant or finish a later attempt. Use existing backend fixtures to test valid one-time synthetic grants; this HTTP fixture cannot mint them.
5. Rotate before Activate and while loading. The current design shows an explicit Retry state after recreation; do not claim saved web state or reusable one-time URL. Test retry against the fixture and then the provider's actual nonce policy. Kill/relaunch process: old panel must not reopen or complete a new attempt.
6. Verify renderer failure, network offline, TLS failure, foreground/background, explicit external fallback and return. Confirm no automatic external browser, credential logs, cookies copied out of WebView, or success inferred from page content.

## S24 acceptance after emulator gate

Only with the user's authorization to install/run a candidate: preserve installed package identity and user data; record APK hash/version/flag; use a real provider approved for embedded verification; complete any human challenge manually; confirm backend grant correlation and one resumed download. Test dark panel at system font scales and portrait/landscape, controls/keyboard, back/cancel, timeout and restart. Do not clear app data or transfer browser cookies. Record Android System WebView version. Until performed, compatibility, CAPTCHA acceptance and download success remain unverified.
