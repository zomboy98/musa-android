package com.zarz.mornye

import android.util.JsonReader
import android.util.JsonToken
import java.io.StringReader

/** Never log a result: it may contain paths or provider metadata. */
internal fun isProgressiveDownloadSuccess(raw: String): Boolean = try {
    JsonReader(StringReader(raw)).use { reader ->
        reader.isLenient = false
        if (reader.peek() != JsonToken.BEGIN_OBJECT) return false
        reader.beginObject()
        var seen = false
        var success = false
        while (reader.hasNext()) {
            if (reader.nextName() == "success") {
                if (seen || reader.peek() != JsonToken.BOOLEAN) return false
                seen = true
                success = reader.nextBoolean()
            } else reader.skipValue()
        }
        reader.endObject()
        seen && success && reader.peek() == JsonToken.END_DOCUMENT
    }
} catch (_: Exception) { false }
