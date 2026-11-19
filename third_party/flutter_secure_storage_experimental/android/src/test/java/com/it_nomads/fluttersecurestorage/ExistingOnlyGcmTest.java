package com.it_nomads.fluttersecurestorage;

import static org.junit.Assert.*;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import org.junit.Test;

public class ExistingOnlyGcmTest {
    @Test public void readsPluginFramingWithoutChangingInputs() throws Exception {
        byte[] key = new byte[16];
        byte[] iv = new byte[12];
        Arrays.fill(key, (byte) 7);
        Arrays.fill(iv, (byte) 9);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, iv));
        byte[] payload = cipher.doFinal("existing-fixture".getBytes(StandardCharsets.UTF_8));
        byte[] framed = new byte[iv.length + payload.length];
        System.arraycopy(iv, 0, framed, 0, iv.length);
        System.arraycopy(payload, 0, framed, iv.length, payload.length);
        byte[] before = framed.clone();
        assertEquals("existing-fixture", new String(ExistingOnlyGcm.decrypt(key, framed), StandardCharsets.UTF_8));
        assertArrayEquals(before, framed);
    }

    @Test public void rejectsTruncationAndCorruption() throws Exception {
        byte[] key = new byte[16];
        try { ExistingOnlyGcm.decrypt(key, new byte[27]); fail(); }
        catch (java.security.GeneralSecurityException expected) { }
        try { ExistingOnlyGcm.decrypt(key, new byte[28]); fail(); }
        catch (java.security.GeneralSecurityException expected) { }
    }
}
