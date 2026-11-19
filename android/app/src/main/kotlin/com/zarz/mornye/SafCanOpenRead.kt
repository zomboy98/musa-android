package com.zarz.mornye

import java.io.Closeable

// Opening and closing the descriptor checks access without reading media bytes.
internal fun safCanOpenRead(open: () -> Closeable?): Boolean = try {
    val descriptor = open()
    if (descriptor == null) false else descriptor.use { true }
} catch (_: Exception) {
    false
}
