package com.it_nomads.fluttersecurestorage;

import java.security.GeneralSecurityException;
import java.util.Arrays;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

// Format experiment only. Does not retrieve keys or access plugin storage.
// Do not expose until the shared asynchronous storage coordinator is proven.
final class ExistingOnlyGcm {
    private ExistingOnlyGcm() {}

    static byte[] decrypt(byte[] key, byte[] framed) throws GeneralSecurityException {
        if (framed == null || framed.length < 28) throw new GeneralSecurityException("Invalid GCM frame");
        if (key == null || key.length != 16) throw new GeneralSecurityException("Invalid GCM key");
        byte[] iv = Arrays.copyOfRange(framed, 0, 12);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, iv));
        return cipher.doFinal(framed, 12, framed.length - 12);
    }
}
