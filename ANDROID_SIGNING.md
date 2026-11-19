# Private MUSA Android signing

Release builds require a private signing configuration. On Windows the default
is `%LOCALAPPDATA%/MUSA/signing/key.properties`, outside the repository. Override
the location with `MUSA_SIGNING_PROPERTIES` when building on another machine.
The Java properties file contains `storeFile`, `keyAlias`, `storePassword` and
`keyPassword`; use forward slashes in an absolute Windows keystore path.

The local MUSA identity uses alias `musa`, PKCS12, RSA 4096 and public subject
`CN=MUSA`. Both the key and properties are restricted to the Windows user.
The properties contain passwords in plaintext: do not print, upload or commit
them. Keep an encrypted recovery copy of the key and configuration separately;
updates require the same signing identity. Git ignores private key formats as
an additional precaution, but signing material belongs outside the checkout.

Debug builds retain Android's debug signing and the `.debug` application suffix.
Release builds must never silently fall back to that key. The explicit
`MUSA_ALLOW_DEBUG_RELEASE_SIGNING=1` switch exists only for CI intermediates
that are subsequently re-signed and verified, or disposable PR validation builds.
Do not deliver those intermediates as MUSA releases.

When creating a replacement identity, let `keytool` prompt for passwords or use
its `-storepass:env` and `-keypass:env` mechanisms with a temporary process-only
environment value. Never include password values in command arguments or logs.
Verify deliverable APKs with `apksigner verify --verbose --print-certs` and
compare the certificate SHA-256 against the intended MUSA identity.

The release workflow pins the MUSA SHA-256 certificate fingerprint to
`C7:0B:72:28:B1:D0:C2:31:D6:BE:C4:C4:C2:D7:5A:B5:A3:BE:E6:E5:EA:10:C5:C9:AD:9E:E8:D4:3D:3D:86:26`.
It rejects missing, multiple or different signing certificates before upload.
Repository CI secrets have not been configured or inspected locally. Publishing
requires the MUSA keystore and credentials in the workflow's existing signing
secrets; inherited upstream credentials will fail this check. This fingerprint
is public and does not reveal the private key or password.

This fingerprint is the current MUSA signing identity. It belongs to the key
`musa-release.p12` (alias `musa`), the definitive release key; the previous
fingerprint is obsolete and must not be accepted by any check.
