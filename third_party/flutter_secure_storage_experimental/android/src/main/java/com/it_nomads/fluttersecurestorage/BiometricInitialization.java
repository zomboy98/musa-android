package com.it_nomads.fluttersecurestorage;

final class BiometricInitialization {
    interface CipherInitializer { void initialize() throws Exception; }
    private BiometricInitialization() {}
    static void finish(CipherInitializer initializer, SecurePreferencesCallback<Void> callback) {
        try { initializer.initialize(); }
        catch (Exception error) { callback.onError(error); return; }
        callback.onSuccess(null);
    }
}
