package com.it_nomads.fluttersecurestorage;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Base64;
import java.nio.charset.StandardCharsets;
import java.security.Key;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.spec.MGF1ParameterSpec;
import java.util.Arrays;
import java.util.HashMap;
import javax.crypto.Cipher;
import javax.crypto.spec.OAEPParameterSpec;
import javax.crypto.spec.PSource;

/** Experimental, current default-format only. Never initializes plugin ciphers. */
public final class ReadExistingOnly {
    private static final String WRAPPED = "AESVGhpcyBpcyB0aGUga2V5IGZvciBhIHNlY3VyZSBzdG9yYWdlIEFFUyBLZXkK";
    private static final ReadAdmission ADMISSION = new ReadAdmission();
    private ReadExistingOnly() {}

    /** Supply a request before calling: an idle queue can execute inline. */
    public static void readExtensionMasterKey(Context context, CancellableRead request, SecurePreferencesCallback<String> callback) {
        Context app = context.getApplicationContext();
        if (!ADMISSION.tryAcquire()) {
            if (request.tryStart()) request.deliver(() -> callback.onError(new IllegalStateException("Existing secure key unavailable")));
            return;
        }
        java.util.concurrent.atomic.AtomicBoolean released = new java.util.concurrent.atomic.AtomicBoolean();
        Runnable release = () -> { if (released.compareAndSet(false, true)) ADMISSION.release(); };
        try {
            FlutterSecureStoragePlugin.STORAGE_QUEUE.submit(done -> {
                if (!request.tryStart()) { release.run(); done.run(); return; }
                String value = null;
                Exception failure = null;
                try { value = readLocked(app); }
                catch (Exception ignored) { failure = new IllegalStateException("Existing secure key unavailable"); }
                finally { release.run(); done.run(); }
                final String result = value;
                final Exception error = failure;
                request.deliver(() -> {
                    if (error == null) callback.onSuccess(result); else callback.onError(error);
                });
            });
        } catch (RuntimeException | Error error) { release.run(); throw error; }
    }

    private static String readLocked(Context context) throws Exception {
        FlutterSecureStorageConfig config = new FlutterSecureStorageConfig(new HashMap<>());
        SharedPreferences data = context.getSharedPreferences(config.getEffectiveDataPrefsName(), Context.MODE_PRIVATE);
        String keyName = config.getSharedPreferencesKeyPrefix() + "_extension_storage_master_key_v2";
        String stored = data.getString(keyName, null);
        if (stored == null) return null;
        SharedPreferences keys = context.getSharedPreferences(config.getEffectiveKeyStoragePrefsName(), Context.MODE_PRIVATE);
        NamespacedConfigSource markers = new NamespacedConfigSource(context, config.getEffectiveDataPrefsName());
        if (MigrationBackup.getBackupStatus(markers, config) != null || data.contains(keyName + "_BACKUP")) throw new IllegalStateException();
        for (String name : keys.getAll().keySet()) if (name.endsWith("_BACKUP")) throw new IllegalStateException();
        // Orphaned per-key markers indicate interrupted backup cleanup even
        // when the overall status has already disappeared. Check both config
        // stores because the plugin still supports legacy global fallback.
        for (String name : markers.getAll().keySet())
            if (name.startsWith(config.getSharedPreferencesKeyPrefix() + "_") && name.endsWith("_MIGRATED")) throw new IllegalStateException();
        SharedPreferences legacyMarkers = context.getSharedPreferences("FlutterSecureStorageConfiguration", Context.MODE_PRIVATE);
        for (String name : legacyMarkers.getAll().keySet())
            if (name.startsWith(config.getSharedPreferencesKeyPrefix() + "_") && name.endsWith("_MIGRATED")) throw new IllegalStateException();
        String keyAlgorithm = markers.getString("FlutterSecureSAlgorithmKey", null);
        String storageAlgorithm = markers.getString("FlutterSecureSAlgorithmStorage", null);
        // A fresh backup-enabled store can have no markers at all: the plugin
        // skips a needless migration and doesn't persist them. Prove its format
        // below with the exact OAEP alias, authenticated GCM, and key length.
        // Partial or conflicting markers remain ambiguous and fail closed.
        boolean markerless = keyAlgorithm == null && storageAlgorithm == null;
        boolean currentFormat = "RSA_ECB_OAEPwithSHA_256andMGF1Padding".equals(keyAlgorithm)
                && "AES_GCM_NoPadding".equals(storageAlgorithm);
        if (!markerless && !currentFormat) throw new IllegalStateException();
        String wrapped = keys.getString(WRAPPED, null);
        if (wrapped == null) throw new IllegalStateException();
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        Key privateKey = store.getKey(context.getPackageName() + ".FlutterSecureStoragePluginKeyOAEP", null);
        if (!(privateKey instanceof PrivateKey)) throw new IllegalStateException();
        Cipher rsa = Cipher.getInstance("RSA/ECB/OAEPPadding", "AndroidKeyStoreBCWorkaround");
        rsa.init(Cipher.UNWRAP_MODE, privateKey, new OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA1, PSource.PSpecified.DEFAULT));
        Key aes = rsa.unwrap(Base64.decode(wrapped, Base64.DEFAULT), "AES", Cipher.SECRET_KEY);
        byte[] raw = aes.getEncoded();
        byte[] plaintext = null;
        try {
            plaintext = ExistingOnlyGcm.decrypt(raw, Base64.decode(stored, Base64.DEFAULT));
            String encoded = new String(plaintext, StandardCharsets.UTF_8);
            byte[] decoded = Base64.decode(encoded, Base64.DEFAULT);
            try { if (decoded.length != 32) throw new IllegalStateException(); }
            finally { Arrays.fill(decoded, (byte) 0); }
            return encoded;
        } finally {
            if (raw != null) Arrays.fill(raw, (byte) 0);
            if (plaintext != null) Arrays.fill(plaintext, (byte) 0);
        }
    }
}
