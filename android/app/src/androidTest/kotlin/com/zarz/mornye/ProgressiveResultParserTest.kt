package com.zarz.mornye
import org.junit.Assert.*
import org.junit.Test
class ProgressiveResultParserTest {
    @Test fun acceptsOnlyBooleanTrueOnCompleteObject() {
        assertTrue(isProgressiveDownloadSuccess("{\"success\":true}"))
        assertTrue(isProgressiveDownloadSuccess(" {\"success\":true,\"path\":\"secret\"} \n"))
        for (text in listOf("{\"success\":false}", "{}", "{\"success\":\"true\"}", "{\"success\":1}", "{\"success\":null}", "[]", "null", "", "{\"success\":", "{\"success\":true} trailing", "{success:true}", "{\"success\":true,}", "{\"success\":true,\"success\":true}")) {
            assertFalse(text, isProgressiveDownloadSuccess(text))
        }
    }
}

