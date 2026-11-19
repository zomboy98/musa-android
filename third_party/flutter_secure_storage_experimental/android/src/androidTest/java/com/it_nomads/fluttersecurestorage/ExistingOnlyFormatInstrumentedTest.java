package com.it_nomads.fluttersecurestorage;

import static org.junit.Assert.*;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.SharedPreferences;
import android.util.Base64;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import java.nio.charset.StandardCharsets;
import java.security.Key;
import java.security.KeyStore;
import java.security.spec.MGF1ParameterSpec;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import javax.crypto.Cipher;
import javax.crypto.spec.OAEPParameterSpec;
import javax.crypto.spec.PSource;
import org.junit.After;
import org.junit.Test;
import org.junit.runner.RunWith;

/** Synthetic isolated fixture; never uses the installed application's secure preferences. */
@RunWith(AndroidJUnit4.class)
public class ExistingOnlyFormatInstrumentedTest {
    private final Context base = InstrumentationRegistry.getInstrumentation().getTargetContext();
    private final String fixture = "existing_only_" + System.nanoTime();
    private final java.util.Set<String> preferenceNames = java.util.Collections.synchronizedSet(new java.util.HashSet<>());
    private final Context context = new ContextWrapper(base) {
        @Override public Context getApplicationContext() { return this; }
        @Override public String getPackageName() { return base.getPackageName() + "." + fixture; }
        @Override public SharedPreferences getSharedPreferences(String name, int mode) {
            String isolated = fixture + "." + name;
            preferenceNames.add(isolated);
            return base.getSharedPreferences(isolated, mode);
        }
    };
    private static final String WRAPPED = "AESVGhpcyBpcyB0aGUga2V5IGZvciBhIHNlY3VyZSBzdG9yYWdlIEFFUyBLZXkK";

    @After public void cleanup() throws Exception {
        for (String name : preferenceNames) base.deleteSharedPreferences(name);
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        java.util.Enumeration<String> aliases = store.aliases();
        while (aliases.hasMoreElements()) {
            String alias = aliases.nextElement();
            if (alias.startsWith(context.getPackageName() + ".")) store.deleteEntry(alias);
        }
    }

    @Test public void pluginWrittenGcmFrameMatchesPureReaderWithoutWrites() throws Exception {
        Map<String, Object> options = new HashMap<>();
        options.put("resetOnError", "false");
        options.put("migrateOnAlgorithmChange", "true");
        options.put("migrateWithBackup", "true");
        options.put("keyCipherAlgorithm", "RSA_ECB_OAEPwithSHA_256andMGF1Padding");
        options.put("storageCipherAlgorithm", "AES_GCM_NoPadding");
        FlutterSecureStorage storage = new FlutterSecureStorage(context);
        CountDownLatch initialized = new CountDownLatch(1);
        AtomicReference<Exception> failure = new AtomicReference<>();
        storage.initialize(new FlutterSecureStorageConfig(options), new SecurePreferencesCallback<Void>() {
            @Override public void onSuccess(Void value) { initialized.countDown(); }
            @Override public void onError(Exception error) { failure.set(error); initialized.countDown(); }
        });
        assertTrue(initialized.await(10, TimeUnit.SECONDS));
        if (failure.get() != null) throw failure.get();
        String keyName = storage.addPrefixToKey("fixture_key");
        storage.write(keyName, "fixture-value");
        SharedPreferences data = context.getSharedPreferences("FlutterSecureStorage", Context.MODE_PRIVATE);
        SharedPreferences wrapped = context.getSharedPreferences("FlutterSecureKeyStorage", Context.MODE_PRIVATE);
        Map<String, ?> beforeData = new HashMap<>(data.getAll());
        Map<String, ?> beforeWrapped = new HashMap<>(wrapped.getAll());
        KeyStore store = KeyStore.getInstance("AndroidKeyStore"); store.load(null);
        Key privateKey = store.getKey(context.getPackageName() + ".FlutterSecureStoragePluginKeyOAEP", null);
        assertNotNull(privateKey);
        Cipher rsa = Cipher.getInstance("RSA/ECB/OAEPPadding", "AndroidKeyStoreBCWorkaround");
        rsa.init(Cipher.UNWRAP_MODE, privateKey, new OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA1, PSource.PSpecified.DEFAULT));
        Key aes = rsa.unwrap(Base64.decode(wrapped.getString(WRAPPED, null), Base64.DEFAULT), "AES", Cipher.SECRET_KEY);
        byte[] plain = ExistingOnlyGcm.decrypt(aes.getEncoded(), Base64.decode(data.getString(keyName, null), Base64.DEFAULT));
        assertEquals("fixture-value", new String(plain, StandardCharsets.UTF_8));
        assertEquals(beforeData, data.getAll());
        assertEquals(beforeWrapped, wrapped.getAll());
    }

    @Test public void missingKeyDoesNotCreateAliasOrWritePreferences() throws Exception {
        SharedPreferences data = context.getSharedPreferences("FlutterSecureStorage", Context.MODE_PRIVATE);
        Map<String, ?> before = new HashMap<>(data.getAll());
        AtomicReference<String> result = new AtomicReference<>();
        AtomicReference<Exception> failure = new AtomicReference<>();
        CountDownLatch done = new CountDownLatch(1);
        ReadExistingOnly.readExtensionMasterKey(context, new CancellableRead(), new SecurePreferencesCallback<String>() {
            @Override public void onSuccess(String value) { result.set(value); done.countDown(); }
            @Override public void onError(Exception error) { failure.set(error); done.countDown(); }
        });
        assertTrue(done.await(5, TimeUnit.SECONDS));
        assertNull(failure.get()); assertNull(result.get()); assertEquals(before, data.getAll());
        KeyStore store = KeyStore.getInstance("AndroidKeyStore"); store.load(null);
        assertFalse(store.containsAlias(context.getPackageName() + ".FlutterSecureStoragePluginKeyOAEP"));
    }

    @Test public void pluginWrittenMasterKeyIsReadableAndBackupBlocksReadWithoutWrites() throws Exception {
        Map<String, Object> options = new HashMap<>();
        options.put("resetOnError", "false"); options.put("migrateOnAlgorithmChange", "true");
        options.put("migrateWithBackup", "true");
        options.put("keyCipherAlgorithm", "RSA_ECB_OAEPwithSHA_256andMGF1Padding");
        options.put("storageCipherAlgorithm", "AES_GCM_NoPadding");
        FlutterSecureStorage storage = new FlutterSecureStorage(context);
        CountDownLatch init = new CountDownLatch(1); AtomicReference<Exception> initError = new AtomicReference<>();
        storage.initialize(new FlutterSecureStorageConfig(options), new SecurePreferencesCallback<Void>() {
            @Override public void onSuccess(Void value) { init.countDown(); }
            @Override public void onError(Exception error) { initError.set(error); init.countDown(); }
        });
        assertTrue(init.await(10, TimeUnit.SECONDS)); if (initError.get() != null) throw initError.get();
        String expected = Base64.encodeToString(new byte[32], Base64.NO_WRAP);
        String prefixed = storage.addPrefixToKey("extension_storage_master_key_v2");
        storage.write(prefixed, expected);
        SharedPreferences data = context.getSharedPreferences("FlutterSecureStorage", Context.MODE_PRIVATE);
        SharedPreferences keys = context.getSharedPreferences("FlutterSecureKeyStorage", Context.MODE_PRIVATE);
        NamespacedConfigSource markers = new NamespacedConfigSource(context, "FlutterSecureStorage");
        // A fresh store with migrateWithBackup=true skips migration and leaves
        // both algorithm markers absent even though it writes current-format data.
        assertNull(markers.getString("FlutterSecureSAlgorithmKey", null));
        assertNull(markers.getString("FlutterSecureSAlgorithmStorage", null));
        Map<String, ?> before = new HashMap<>(data.getAll()), beforeKeys = new HashMap<>(keys.getAll());
        Map<String, ?> beforeMarkers = new HashMap<>(markers.getAll());
        AtomicReference<String> value = new AtomicReference<>(); AtomicReference<Exception> failure = new AtomicReference<>();
        CountDownLatch done = new CountDownLatch(1);
        ReadExistingOnly.readExtensionMasterKey(context, new CancellableRead(), new SecurePreferencesCallback<String>() {
            @Override public void onSuccess(String found) { value.set(found); done.countDown(); }
            @Override public void onError(Exception error) { failure.set(error); done.countDown(); }
        });
        assertTrue(done.await(5, TimeUnit.SECONDS)); assertNull(failure.get()); assertEquals(expected, value.get());
        assertEquals(before, data.getAll()); assertEquals(beforeKeys, keys.getAll());
        assertEquals(beforeMarkers, markers.getAll());
        assertTrue(markers.edit().putString("FlutterSecureSAlgorithmKey", "RSA_ECB_OAEPwithSHA_256andMGF1Padding").commit());
        Map<String, ?> partialMarkers = new HashMap<>(markers.getAll());
        assertReadFails(); assertEquals(partialMarkers, markers.getAll());
        assertTrue(markers.edit().remove("FlutterSecureSAlgorithmKey").commit());
        assertTrue(data.edit().putString(prefixed + "_BACKUP", "fixture").commit());
        Map<String, ?> backedUp = new HashMap<>(data.getAll());
        CountDownLatch blocked = new CountDownLatch(1); AtomicReference<Exception> blockedError = new AtomicReference<>();
        ReadExistingOnly.readExtensionMasterKey(context, new CancellableRead(), new SecurePreferencesCallback<String>() {
            @Override public void onSuccess(String ignored) { blocked.countDown(); }
            @Override public void onError(Exception error) { blockedError.set(error); blocked.countDown(); }
        });
        assertTrue(blocked.await(5, TimeUnit.SECONDS)); assertNotNull(blockedError.get());
        assertEquals(backedUp, data.getAll()); assertEquals(beforeKeys, keys.getAll());
        assertTrue(data.edit().remove(prefixed + "_BACKUP").commit());
        assertTrue(markers.edit().putBoolean(prefixed + "_MIGRATED", true).commit());
        Map<String, ?> orphaned = new HashMap<>(markers.getAll());
        assertReadFails(); assertEquals(orphaned, markers.getAll());
        assertTrue(markers.edit().remove(prefixed + "_MIGRATED").commit());
        // v9 data markers can remain after a completed migration. Current
        // authenticated config markers govern the format; preserve both.
        assertTrue(data.edit().putString("FlutterSecureSAlgorithmKey", "RSA_ECB_PKCS1Padding")
            .putString("FlutterSecureSAlgorithmStorage", "AES_CBC_PKCS7Padding").commit());
        CountDownLatch legacyDataDone = new CountDownLatch(1); AtomicReference<String> legacyDataValue = new AtomicReference<>();
        ReadExistingOnly.readExtensionMasterKey(context, new CancellableRead(), new SecurePreferencesCallback<String>() {
            @Override public void onSuccess(String value) { legacyDataValue.set(value); legacyDataDone.countDown(); }
            @Override public void onError(Exception error) { legacyDataDone.countDown(); }
        });
        assertTrue(legacyDataDone.await(5, TimeUnit.SECONDS)); assertEquals(expected, legacyDataValue.get());
        assertTrue(data.edit().remove(prefixed + "_BACKUP").putString(prefixed, "not-valid-ciphertext").commit());
        Map<String, ?> corrupt = new HashMap<>(data.getAll());
        assertReadFails(); assertEquals(corrupt, data.getAll()); assertEquals(beforeKeys, keys.getAll());
        assertTrue(data.edit().putString(prefixed, (String) before.get(prefixed)).commit());
        assertTrue(markers.edit().putString("FlutterSecureSAlgorithmKey", "RSA_ECB_PKCS1Padding").commit());
        Map<String, ?> legacy = new HashMap<>(data.getAll()), legacyMarkers = new HashMap<>(markers.getAll());
        assertReadFails(); assertEquals(legacy, data.getAll()); assertEquals(legacyMarkers, markers.getAll());
        assertTrue(markers.edit().putString("FlutterSecureSAlgorithmKey", "RSA_ECB_OAEPwithSHA_256andMGF1Padding").commit());
        KeyStore fixtureStore = KeyStore.getInstance("AndroidKeyStore"); fixtureStore.load(null);
        fixtureStore.deleteEntry(context.getPackageName() + ".FlutterSecureStoragePluginKeyOAEP");
        assertReadFails();
        assertEquals(legacy, data.getAll()); assertEquals(beforeKeys, keys.getAll());
        assertFalse(fixtureStore.containsAlias(context.getPackageName() + ".FlutterSecureStoragePluginKeyOAEP"));
    }

    private void assertReadFails() throws Exception {
        CountDownLatch done = new CountDownLatch(1); AtomicReference<Exception> failure = new AtomicReference<>();
        ReadExistingOnly.readExtensionMasterKey(context, new CancellableRead(), new SecurePreferencesCallback<String>() {
            @Override public void onSuccess(String value) { done.countDown(); }
            @Override public void onError(Exception error) { failure.set(error); done.countDown(); }
        });
        assertTrue(done.await(5, TimeUnit.SECONDS)); assertNotNull(failure.get());
    }

    @Test public void readerWaitsForTheSharedPluginQueue() throws Exception {
        AtomicReference<Runnable> finish = new AtomicReference<>();
        FlutterSecureStoragePlugin.STORAGE_QUEUE.submit(finish::set);
        CountDownLatch completed = new CountDownLatch(1);
        ReadExistingOnly.readExtensionMasterKey(context, new CancellableRead(), new SecurePreferencesCallback<String>() {
            @Override public void onSuccess(String value) { completed.countDown(); }
            @Override public void onError(Exception error) { completed.countDown(); }
        });
        try {
            assertFalse(completed.await(100, TimeUnit.MILLISECONDS));
        } finally { finish.get().run(); }
        assertTrue(completed.await(5, TimeUnit.SECONDS));
    }

    @Test public void cancelledQueuedReaderDoesNotTouchPreferencesOrCallback() throws Exception {
        AtomicReference<Runnable> finish = new AtomicReference<>();
        FlutterSecureStoragePlugin.STORAGE_QUEUE.submit(finish::set);
        java.util.concurrent.atomic.AtomicInteger reads = new java.util.concurrent.atomic.AtomicInteger();
        java.util.concurrent.atomic.AtomicInteger callbacks = new java.util.concurrent.atomic.AtomicInteger();
        Context tracked = new ContextWrapper(context) {
            @Override public Context getApplicationContext() { return this; }
            @Override public SharedPreferences getSharedPreferences(String name, int mode) {
                reads.incrementAndGet();
                return super.getSharedPreferences(name, mode);
            }
        };
        try {
            CancellableRead request = new CancellableRead();
            ReadExistingOnly.readExtensionMasterKey(tracked, request, new SecurePreferencesCallback<String>() {
                @Override public void onSuccess(String ignored) { callbacks.incrementAndGet(); }
                @Override public void onError(Exception ignored) { callbacks.incrementAndGet(); }
            });
            request.cancel();
        } finally { finish.get().run(); }
        assertEquals(0, reads.get());
        assertEquals(0, callbacks.get());
    }

    @Test public void preCancelledInlineReaderDoesNotTouchPreferencesOrCallback() {
        java.util.concurrent.atomic.AtomicInteger reads = new java.util.concurrent.atomic.AtomicInteger();
        java.util.concurrent.atomic.AtomicInteger callbacks = new java.util.concurrent.atomic.AtomicInteger();
        Context tracked = new ContextWrapper(context) {
            @Override public Context getApplicationContext() { return this; }
            @Override public SharedPreferences getSharedPreferences(String name, int mode) {
                reads.incrementAndGet(); return super.getSharedPreferences(name, mode);
            }
        };
        CancellableRead request = new CancellableRead();
        request.cancel();
        ReadExistingOnly.readExtensionMasterKey(tracked, request, new SecurePreferencesCallback<String>() {
            @Override public void onSuccess(String ignored) { callbacks.incrementAndGet(); }
            @Override public void onError(Exception ignored) { callbacks.incrementAndGet(); }
        });
        assertEquals(0, reads.get()); assertEquals(0, callbacks.get());
    }

    @Test public void repeatedCancelledAttemptsDoNotAccumulateBehindBlockedPluginQueue() throws Exception {
        AtomicReference<Runnable> finish = new AtomicReference<>();
        FlutterSecureStoragePlugin.STORAGE_QUEUE.submit(finish::set);
        java.util.concurrent.atomic.AtomicInteger rejected = new java.util.concurrent.atomic.AtomicInteger();
        java.util.concurrent.atomic.AtomicInteger firstCallbacks = new java.util.concurrent.atomic.AtomicInteger();
        try {
            CancellableRead first = new CancellableRead();
            ReadExistingOnly.readExtensionMasterKey(context, first, new SecurePreferencesCallback<String>() {
                @Override public void onSuccess(String ignored) { firstCallbacks.incrementAndGet(); }
                @Override public void onError(Exception ignored) { firstCallbacks.incrementAndGet(); }
            });
            first.cancel();
            for (int i = 0; i < 100; i++) {
                ReadExistingOnly.readExtensionMasterKey(context, new CancellableRead(), new SecurePreferencesCallback<String>() {
                    @Override public void onSuccess(String ignored) { fail("read must be rejected"); }
                    @Override public void onError(Exception ignored) { rejected.incrementAndGet(); }
                });
            }
            assertEquals(100, rejected.get());
            assertEquals(0, firstCallbacks.get());
        } finally { finish.get().run(); }
        assertEquals(0, firstCallbacks.get());
        CountDownLatch after = new CountDownLatch(1);
        ReadExistingOnly.readExtensionMasterKey(context, new CancellableRead(), new SecurePreferencesCallback<String>() {
            @Override public void onSuccess(String ignored) { after.countDown(); }
            @Override public void onError(Exception error) { throw new AssertionError(error); }
        });
        assertTrue(after.await(1, TimeUnit.SECONDS));
    }
}
