package com.zarz.mornye

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.net.http.SslError
import android.os.Bundle
import android.os.SystemClock
import android.view.View
import android.view.WindowManager
import android.webkit.*
import android.widget.*
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import java.io.ByteArrayInputStream
import org.json.JSONTokener

/**
 * Always-invisible extension verification with an origin-scoped return channel.
 *
 * The Activity is translucent, non-touchable and non-focusable (WebView at alpha 0)
 * and is NEVER shown to the user: there is no reveal path. It has a hard deadline
 * ([VerificationDeadline.HARD_TIMEOUT_MS]); when it expires the Activity closes
 * itself and answers [UNAVAILABLE] so Dart silently falls back to the next
 * provider. Nothing is ever shown, so every non-grant ending is [UNAVAILABLE].
 *
 * `open` is answered exactly once with a status string (see Dart
 * `VerificationPanelReply`):
 * - [GRANTED]: the callback was forwarded.
 * - [CLOSED] / [ERROR]: kept for protocol compatibility; no longer produced
 *   because nothing is ever presented.
 * - [BUSY]: another verification is still pending; nothing new was started.
 * - [UNAVAILABLE]: no grant (invalid request, activity could not be started,
 *   WebView unavailable, blocked destination, SSL/load error, closed, timeout).
 */
internal object ExtensionVerificationPanel {
    const val CHANNEL = "com.zarz.mornye/verification_panel"
    const val GRANTED = "granted"
    const val CLOSED = "closed"
    const val ERROR = "error"
    const val BUSY = "busy"
    const val UNAVAILABLE = "unavailable"

    /**
     * Rollback switch. true (default): the invisible WebView lives inside the
     * main Activity ([ExtensionVerificationHost]), no Activity is launched.
     * false: legacy behaviour, one translucent [ExtensionVerificationActivity]
     * per verification.
     */
    const val USE_EMBEDDED_HOST = true

    private val slot = VerificationSlot()
    private var pending: MethodChannel.Result? = null
    private var activity = WeakReference<ExtensionVerificationActivity>(null)
    private var owner = WeakReference<Activity>(null)
    private var host: ExtensionVerificationHost? = null

    private fun ownerCanHost(a: Activity?): Boolean {
        val started = (a as? LifecycleOwner)?.lifecycle?.currentState
            ?.isAtLeast(Lifecycle.State.STARTED) == true
        return VerificationHostPolicy.canHost(
            hasOwner = a != null,
            finishingOrDestroyed = a == null || a.isFinishing || a.isDestroyed,
            startedOrResumed = started,
        )
    }

    fun register(owner: Activity, messenger: BinaryMessenger) {
        this.owner = WeakReference(owner)
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val url = call.argument<String>("url").orEmpty()
                    val id = call.argument<String>("id").orEmpty()
                    when (slot.begin(id, VerificationNavigationPolicy(url).valid)) {
                        // Another verification is pending: never stack a second one.
                        VerificationSlot.Begin.BUSY -> result.success(BUSY)
                        VerificationSlot.Begin.INVALID -> result.success(UNAVAILABLE)
                        VerificationSlot.Begin.STARTED -> {
                            pending = result
                            if (USE_EMBEDDED_HOST) openEmbedded(id, url)
                            else openLegacy(owner, id, url)
                        }
                    }
                }
                "close" -> {
                    val id = call.argument<String>("id")
                    if (slot.isActive(id)) {
                        host?.cancel() // finishes through complete(); no-op if already done
                        activity.get()?.finish()
                        complete(id, dismissed())
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun openEmbedded(id: String, url: String) {
        val current = owner.get()
        if (current == null || !ownerCanHost(current)) {
            complete(id, UNAVAILABLE) // No foreground main Activity: same as today.
            return
        }
        val created = try {
            ExtensionVerificationHost(current, url, VerificationNavigationPolicy(url)) { status ->
                complete(id, status)
            }
        } catch (_: Exception) {
            complete(id, UNAVAILABLE)
            return
        }
        host = created
        val started = try { created.start() } catch (_: Exception) { false }
        if (!started) {
            host = null
            complete(id, UNAVAILABLE)
        }
    }

    private fun openLegacy(owner: Activity, id: String, url: String) {
        try {
            owner.startActivity(Intent(owner, ExtensionVerificationActivity::class.java)
                .putExtra("url", url).putExtra("id", id))
        } catch (_: Exception) { complete(id, UNAVAILABLE) }
    }

    /** MainActivity is going away: end any hosted verification silently. */
    fun onOwnerDestroyed(destroyed: Activity) {
        if (owner.get() === destroyed) host?.cancel()
    }

    fun attach(id: String, owner: ExtensionVerificationActivity): Boolean {
        if (!slot.isActive(id) || pending == null) return false
        activity = WeakReference(owner)
        return true
    }


    /** Nothing is ever presented: every non-grant ending is silent. */
    fun dismissed(): String = UNAVAILABLE

    /** Nothing is ever presented: failures are silent too. */
    fun failed(): String = UNAVAILABLE

    fun complete(id: String?, status: String) {
        if (!slot.finish(id)) return
        val result = pending
        pending = null
        activity.clear()
        host = null
        result?.success(status)
    }
}


class ExtensionVerificationActivity : Activity() {
    private lateinit var web: WebView
    private val deadline = VerificationDeadline({ SystemClock.elapsedRealtime() })
    private lateinit var policy: VerificationNavigationPolicy
    private var requestId = ""
    private var url = ""
    private var callbackForwarded = false
    private val fallbackProbe = object : Runnable {
        override fun run() {
            if (isFinishing || callbackForwarded || !policy.allowsPage(web.url.orEmpty())) return
            // Read only the page's own fallback after it has been revealed; this
            // does not click or complete the verification challenge.
            web.evaluateJavascript(
                "(function(){var b=document.getElementById('fallback');" +
                    "var u=document.getElementById('fallbackUrl');" +
                    "return b&&b.getAttribute('data-shown')&&" +
                    "getComputedStyle(b).display!=='none'&&u?u.textContent:null;})()"
            ) { result ->
                if (isFinishing || callbackForwarded || !policy.allowsPage(web.url.orEmpty())) return@evaluateJavascript
                val callback = try { JSONTokener(result).nextValue() as? String } catch (_: Exception) { null }
                if (callback != null && policy.isBridgeMessageCandidate(web.url.orEmpty(), true, callback)) {
                    forwardCallback(Uri.parse(callback))
                } else {
                    web.postDelayed(this, 1000L)
                }
            }
        }
    }

    /** Hard deadline: never wait for the user; Dart falls back silently. */
    private val hardTimeout = Runnable {
        if (!isFinishing && deadline.expired()) showFailure()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestId = intent.getStringExtra("id").orEmpty()
        url = intent.getStringExtra("url").orEmpty()
        policy = VerificationNavigationPolicy(url)
        if (!policy.valid || !ExtensionVerificationPanel.attach(requestId, this)) { finish(); return }
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        // Always invisible: never intercept touches, focus or the back key.
        window.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE)
        window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        window.setBackgroundDrawable(android.graphics.drawable.ColorDrawable(Color.TRANSPARENT))
        overridePendingTransition(0, 0)
        val root = FrameLayout(this).apply { setBackgroundColor(Color.TRANSPARENT) }
        web = try {
            WebView(this)
        } catch (_: Exception) {
            // Missing/updating WebView provider: nothing was presented.
            ExtensionVerificationPanel.complete(requestId, ExtensionVerificationPanel.UNAVAILABLE)
            finish()
            return
        }
        web.apply {
            // Attached full-screen but invisible: keeps loading and running JS.
            // Not exactly 0: a fully transparent view is skipped by the renderer, so the
            // page would get no frames (rAF throttled) and its challenge would stall.
            alpha = 0.01f
            setBackgroundColor(Color.WHITE)
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            settings.setSupportMultipleWindows(false)
            CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
            webViewClient = object : WebViewClient() {
                override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                    if (request.isForMainFrame && !policy.allowsPage(request.url.toString())) {
                        view.post { showFailure() }
                        return WebResourceResponse("text/plain", "UTF-8", ByteArrayInputStream(ByteArray(0)))
                    }
                    return null
                }
                override fun onPageStarted(view: WebView, target: String, favicon: android.graphics.Bitmap?) {
                    // POST/redirect navigations do not always call shouldOverrideUrlLoading.
                    // This additional guard is not a network sandbox; instrumented tests
                    // must verify the concrete WebView/provider combination.
                    if (!policy.allowsPage(target)) {
                        view.stopLoading()
                        showFailure()
                    }
                }
                override fun onPageFinished(view: WebView, target: String) {
                    if (policy.allowsPage(target)) {
                        view.removeCallbacks(fallbackProbe)
                        // The page reveals its fallback eight seconds after it
                        // verifies. Keep watching if verification takes longer.
                        view.postDelayed(fallbackProbe, 9000L)
                    }
                }
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    if (!request.isForMainFrame) return !request.url.scheme.equals("https", true)
                    val target = request.url.toString()
                    if (policy.isCallbackCandidate(target)) {
                        forwardCallback(request.url)
                        return true
                    }
                    if (policy.allowsPage(target)) return false
                    showFailure()
                    return true
                }
                override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
                    handler.cancel(); showFailure()
                }
                override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                    if (request.isForMainFrame) showFailure()
                }
            }
        }
        root.addView(web, FrameLayout.LayoutParams(-1, -1))
        installReturnChannel()
        setContentView(root)
        deadline.start()
        web.postDelayed(hardTimeout, deadline.remainingMs())
        web.loadUrl(url)
    }

    override fun finish() {
        super.finish()
        overridePendingTransition(0, 0)
    }

    /** Any failure (and the hard timeout) is silent: UNAVAILABLE, then close. */
    private fun showFailure() {
        deadline.markCompleted()
        ExtensionVerificationPanel.complete(requestId, ExtensionVerificationPanel.failed())
        finish()
    }


    /** Accept messages only from the exact HTTPS origin and the top-level frame. */
    private fun installReturnChannel(): Boolean {
        val origin = policy.bridgeOriginRule() ?: return false
        return try {
            if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) return false
            WebViewCompat.addWebMessageListener(
                web, "MornyeGrant", setOf(origin),
                object : WebViewCompat.WebMessageListener {
                    override fun onPostMessage(
                        view: WebView,
                        message: WebMessageCompat,
                        sourceOrigin: Uri,
                        isMainFrame: Boolean,
                        replyProxy: JavaScriptReplyProxy,
                    ) {
                        val callback = message.data ?: return
                        if (policy.isBridgeMessageCandidate(sourceOrigin.toString(), isMainFrame, callback)) {
                            forwardCallback(Uri.parse(callback))
                        }
                    }
                },
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    /** Preserve the existing inbox and backend state/grant validation. */
    private fun forwardCallback(callback: Uri) {
        if (callbackForwarded) return
        callbackForwarded = true
        try {
            startActivity(Intent(this, MainActivity::class.java)
                .setAction(Intent.ACTION_VIEW).setData(callback)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP))
            deadline.markCompleted()
            ExtensionVerificationPanel.complete(requestId, ExtensionVerificationPanel.GRANTED)
            finish()
        } catch (_: Exception) {
            callbackForwarded = false
            showFailure()
        }
    }

    override fun onDestroy() {
        deadline.markCompleted()
        if (::web.isInitialized) {
            web.removeCallbacks(hardTimeout)
            web.removeCallbacks(fallbackProbe); web.stopLoading(); web.removeAllViews(); web.destroy()
        }
        if (!isChangingConfigurations) {
            ExtensionVerificationPanel.complete(requestId, ExtensionVerificationPanel.dismissed())
        }
        super.onDestroy()
    }
}
