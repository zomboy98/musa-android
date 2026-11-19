# Experimental, disconnected fork

This is an unmodified starting copy of `flutter_secure_storage` 10.3.4 from
the local pub.dev package cache. Upstream repository:
https://github.com/mogol/flutter_secure_storage/tree/develop/flutter_secure_storage

The package's original `LICENSE` and federated platform declarations are
retained. The application does not depend on this directory. No worker or
application code may use this experiment until asynchronous serialization,
read-only key access, migration compatibility and instrumentation tests pass.

In particular, holding a Java monitor only around `initialize` is not
sufficient: its completion callback may execute asynchronously. A future
serialization mechanism must cover initialization and the resulting operation
across instances and release its permit on every callback/failure path.

## Isolated Android test build

The bundled `example` depends on this fork by relative path and has its own
application ID `org.mornye.experimental.securestorage` and instrumentation ID
`org.mornye.experimental.securestorage.test`; neither is the MUSA app ID.
The example's Android test source contains a copy of the app's
`SecureStorageMigrationTest`, with only its package changed to access this
fork's package-private constructor. The app test source set also references
the plugin's existing-only format and preservation fixture directly, so the
same fixture can run under the example's targetSdk 36 without maintaining a
second copy. Both use synthetic values
and per-test isolated preference names and Android Keystore aliases.

Future build steps, from `example`, with a configured Flutter/Android SDK:

1. Run `flutter pub get` and build the debug example once to configure the
   generated Android wrapper and local SDK paths.
2. From `example/android`, build `:app:assembleDebugAndroidTest` for both
   migration and existing-only fixtures, using the generated Gradle wrapper.
   The plugin library's separate self-targeted test APK currently targets 23;
   Android 15 and later reject fresh installations with targetSdk below 24.
   The app test APK targets the example application instead. Building neither
   installs an APK.
3. Before installing or running on a device, verify the resulting application,
   test package IDs and target package in the generated manifests. Run only in
   a separate, disposable test environment approved for this work.

The example sets one Gradle worker and limits the Gradle heap to 1536 MiB.
These commands are a proposed recipe: neither APK has been built or run yet,
and compatibility with a particular Flutter/AGP installation is unverified.
