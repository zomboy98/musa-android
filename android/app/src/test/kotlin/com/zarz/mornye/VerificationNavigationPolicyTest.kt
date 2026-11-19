package com.zarz.mornye

import org.junit.Assert.*
import org.junit.Test

class VerificationNavigationPolicyTest {
    @Test fun permitsOnlyOriginalHttpsOrigin() {
        val policy = VerificationNavigationPolicy("https://verify.example/start?state=secret")
        assertTrue(policy.allowsPage("https://verify.example/next"))
        for (url in listOf("http://verify.example/", "https://evil.example/", "https://verify.example.evil/", "https://user@verify.example/", "file:///secret", "javascript:alert(1)", "https://verify.example:444/")) {
            assertFalse(url, policy.allowsPage(url))
        }
    }
    @Test fun rejectsInvalidInitialUrl() {
        for (url in listOf("http://verify.example/", "https://user@verify.example/", "javascript:x")) {
            assertFalse(VerificationNavigationPolicy(url).valid)
        }
    }
    @Test fun callbacksAreOnlyCandidatesForExistingValidator() {
        val policy = VerificationNavigationPolicy("https://verify.example/?state=x")
        assertTrue(policy.isCallbackCandidate("mornye://musa-session-grant?state=x&grant=y"))
        assertTrue(policy.isCallbackCandidate("mornye://session-grant?state=x&grant=y"))
        assertFalse(policy.isCallbackCandidate("intent://session-grant"))
        assertFalse(policy.isCallbackCandidate("mornye://unrelated"))
        assertFalse(policy.isCallbackCandidate("mornye://callback?state=x&code=y"))
        assertFalse(policy.isCallbackCandidate("mornye://session-grant"))
        assertFalse(policy.isCallbackCandidate("mornye://session-grant?state=x"))
        assertFalse(policy.isCallbackCandidate("mornye://session-grant?state=%ZZ&grant=y"))
        assertFalse(policy.isCallbackCandidate("mornye://session-grant?state=x&state=y&grant=z"))
        assertFalse(policy.isCallbackCandidate("mornye://session-grant?state=other&grant=z"))
        assertFalse(VerificationNavigationPolicy("https://verify.example/")
            .isCallbackCandidate("mornye://session-grant?state=x&grant=y"))
        assertTrue(VerificationNavigationPolicy("https://verify.example/?cb=mornye%3A%2F%2Fsession-grant%3Fstate%3Dx")
            .isCallbackCandidate("mornye://session-grant?state=x&grant=y"))
    }

    @Test fun bridgeAcceptsOnlyTheMatchingCallbackFromTheMainFrameOrigin() {
        val policy = VerificationNavigationPolicy("https://verify.example/?state=x")
        fun accepted(origin: String, mainFrame: Boolean, message: String) =
            policy.isBridgeMessageCandidate(origin, mainFrame, message)
        val valid = "mornye://session-grant?state=x&grant=fixture"
        assertEquals("https://verify.example", policy.bridgeOriginRule())
        assertTrue(accepted("https://verify.example", true, valid))
        assertFalse(accepted("https://other.example", true, valid))
        assertFalse(accepted("https://verify.example", false, valid))
        assertFalse(accepted("https://verify.example", true, "mornye://session-grant?state=wrong&grant=fixture"))
        assertFalse(accepted("https://verify.example", true, "fixture"))
        assertFalse(accepted("http://verify.example", true, valid))
        assertFalse(accepted("https://verify.example:444", true, valid))
    }

    @Test fun bridgeMatchesStateNestedInTheChallengeCallback() {
        val policy = VerificationNavigationPolicy(
            "https://verify.example/v2/challenge?id=fixture&cb=" +
                "mornye%3A%2F%2Fsession-grant%3Fcb_version%3Dv2grant%26state%3Dx"
        )
        val callback = "mornye://session-grant?cb_version=v2grant&state=x&grant=fixture"
        assertTrue(policy.isBridgeMessageCandidate("https://verify.example", true, callback))
        assertFalse(policy.isBridgeMessageCandidate(
            "https://verify.example", true, callback.replace("state=x", "state=other")
        ))
        assertFalse(policy.isBridgeMessageCandidate(
            "https://verify.example", true, callback + "&grant=duplicate"
        ))
    }
}
