package com.zarz.mornye

import android.app.Activity
import android.os.Bundle
import android.widget.TextView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer

/** TEST-VARIANT ONLY. Opens real production panel without a production URL override. */
class VerificationFixtureHostActivity : Activity() {
    companion object {
        const val FIXTURE_URL = "https://localhost:9443/verify?state=musa-fixture-state"
        /** Native `open` reply statuses (see ExtensionVerificationPanel). */
        private val KNOWN_STATUSES = setOf("granted", "closed", "error", "busy", "unavailable")

        /**
         * Raw status string exactly as returned by `open`: granted/closed/error/busy/unavailable.
         * Null while no reply has arrived, when the reply was null, or when it was not a String.
         * Prefer this for assertions; it is the only lossless value.
         */
        @Volatile var panelStatus: String? = null

        /** True once any reply envelope was delivered (distinguishes "no reply yet" from a null reply). */
        @Volatile var panelReplied: Boolean = false

        /** Set when the reply envelope was an error or the payload was not a recognized status. */
        @Volatile var panelReplyAnomaly: String? = null

        /**
         * Legacy compatibility view of [panelStatus]; NOT an authentication result.
         * true only for "granted"; false for any other recognized status (closed, error, busy,
         * unavailable); null when there is no reply or the reply was unrecognized/anomalous.
         * Never infer success from false/null, and never read true as login success.
         */
        @Volatile var panelReturned: Boolean? = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        check(packageName == "org.musa.music.verificationfixture")
        setContentView(TextView(this).apply {
            text = "Synthetic panel harness; no production session."
        })
        if (savedInstanceState != null) return
        panelReturned = null
        panelStatus = null
        panelReplied = false
        panelReplyAnomaly = null
        val messenger = FixtureMessenger()
        ExtensionVerificationPanel.register(this, messenger)
        val encoded = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall("open", mapOf(
            "id" to "synthetic-panel-${System.nanoTime()}", "url" to FIXTURE_URL,
        )))
        encoded.flip()
        messenger.handler!!.onMessage(encoded) { envelope ->
            envelope?.flip()
            var status: String? = null
            var anomaly: String? = null
            if (envelope == null) {
                anomaly = "null-envelope"
            } else {
                try {
                    val decoded = StandardMethodCodec.INSTANCE.decodeEnvelope(envelope)
                    when {
                        decoded == null -> anomaly = "null-reply"
                        decoded !is String -> anomaly = "non-string-reply:${decoded.javaClass.simpleName}"
                        decoded !in KNOWN_STATUSES -> { status = decoded; anomaly = "unknown-status" }
                        else -> status = decoded
                    }
                } catch (e: Exception) {
                    // Error envelope (FlutterException) or undecodable bytes; no status is invented.
                    anomaly = "error-envelope:${e.javaClass.simpleName}"
                }
            }
            panelReplyAnomaly = anomaly
            panelStatus = status
            panelReturned = if (status != null && status in KNOWN_STATUSES) status == "granted" else null
            panelReplied = true // last, so readers polling it see a consistent state
        }
    }

    private class FixtureMessenger : BinaryMessenger {
        var handler: BinaryMessenger.BinaryMessageHandler? = null
        override fun send(channel: String, message: ByteBuffer?) = Unit
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) = Unit
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            check(channel == ExtensionVerificationPanel.CHANNEL)
            this.handler = handler
        }
    }
}
