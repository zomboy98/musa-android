package com.zarz.mornye

import java.io.Closeable
import java.io.FileNotFoundException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SafCanOpenReadTest {
    @Test fun closesAnOpenedDescriptor() {
        var closed = false
        assertTrue(safCanOpenRead { Closeable { closed = true } })
        assertTrue(closed)
    }

    @Test fun missingOrRevokedAccessIsUnavailable() {
        assertFalse(safCanOpenRead { null })
        assertFalse(safCanOpenRead { throw SecurityException("revoked") })
        assertFalse(safCanOpenRead { throw FileNotFoundException() })
        assertFalse(safCanOpenRead { Closeable { throw java.io.IOException() } })
    }
}
