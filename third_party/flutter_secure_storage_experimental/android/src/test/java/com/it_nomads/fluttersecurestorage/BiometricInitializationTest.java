package com.it_nomads.fluttersecurestorage;

import static org.junit.Assert.*;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.Test;

public class BiometricInitializationTest {
    @Test public void cipherFailureReportsOnlyError() {
        AtomicInteger success = new AtomicInteger(), errors = new AtomicInteger();
        Exception expected = new Exception("fixture");
        BiometricInitialization.finish(() -> { throw expected; }, new SecurePreferencesCallback<Void>() {
            @Override public void onSuccess(Void ignored) { success.incrementAndGet(); }
            @Override public void onError(Exception error) { assertSame(expected, error); errors.incrementAndGet(); }
        });
        assertEquals(0, success.get()); assertEquals(1, errors.get());
    }
    @Test public void cipherSuccessReportsOnlySuccess() {
        AtomicInteger success = new AtomicInteger(), errors = new AtomicInteger();
        BiometricInitialization.finish(() -> {}, new SecurePreferencesCallback<Void>() {
            @Override public void onSuccess(Void ignored) { success.incrementAndGet(); }
            @Override public void onError(Exception error) { errors.incrementAndGet(); }
        });
        assertEquals(1, success.get()); assertEquals(0, errors.get());
    }
}
