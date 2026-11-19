package com.zarz.mornye

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Rect
import android.net.Uri
import android.net.http.SslError
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.webkit.CookieManager
import android.webkit.SslErrorHandler
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import java.io.ByteArrayInputStream
import org.json.JSONTokener

/**
 * Invisible full-screen layer that never takes touches, key events or focus.
 * It is added on top of MainActivity's content view, so the main Activity is
 * never paused/stopped and the IME is never closed.
 */
internal class InvisibleVerificationLayer(context: Context) : FrameLayout(context) {
    init {
        // Not exactly 0: a fully transparent view is skipped by the renderer, so the
        // page would get no frames (rAF throttled) and its challenge would stall.
        alpha = 0.01f
        isClickable = false
        isLongClickable = false
        isFocusable = false
        isFocusableInTouchMode = false
        descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        if (Build.VERSION.SDK_INT >= 26) {
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
        }
        setBackgroundColor(Color.TRANSPARENT)
    }

    // Returning false lets the touch fall through to the views underneath (Flutter).
    override fun dispatchTouchEvent(ev: MotionEvent?): Boolean = false
    override fun onInterceptTouchEvent(ev: MotionEvent?): Boolean = false
    override fun onTouchEvent(event: MotionEvent?): Boolean = false
    override fun dispatchGenericMotionEvent(event: MotionEvent?): Boolean = false
    override fun dispatchKeyEvent(event: KeyEvent?): Boolean = false
    override fun requestFocus(direction: Int, previouslyFocusedRect: Rect?): Boolean = false
}

/** WebView that never asks for focus nor attaches to the input method. */
internal class NoFocusWebView(context: Context) : WebView(context) {
    init {
        isFocusable = false
        isFocusableInTouchMode = false
        isClickable = false
        isLongClickable = false
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
    }

    override fun requestFocus(direction: Int, previouslyFocusedRect: Rect?): Boolean = false
    override fun onCheckIsTextEditor(): Boolean = false
    override fun onCreateInputConnection(outAttrs: EditorInfo?): InputConnection? = null
    override fun dispatchTouchEvent(event: MotionEvent?): Boolean = false
    override fun onTouchEvent(event: MotionEvent?): Boolean = false
    override fun dispatchGenericMotionEvent(event: MotionEvent?): Boolean = false
    override fun dispatchKeyEvent(event: KeyEvent?): Boolean = false
}

/**
 * One invisible verification hosted INSIDE the main Activity (no Activity
 * switch). Same lifecycle as the legacy [ExtensionVerificationActivity]:
 * hard deadline ([VerificationDeadline]), a single WebView per verification,
 * destroyed on completion. [onFinished] is invoked exactly once with the
 * status (granted / unavailable) after the view has been torn down.
 *
 * FLAG_SECURE is NOT applied (it would be a flag of the main window). The
 * content is at alpha 0.01 and not touchable/focusable.
 */
internal class ExtensionVerificationHost(
    private val owner: Activity,
    private val url: String,
    private val policy: VerificationNavigationPolicy,
    private val onFinished: (String) -> Unit,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val deadline = VerificationDeadline({ SystemClock.elapsedRealtime() })
    private var layer: InvisibleVerificationLayer? = null
    private var web: WebView? = null
    private var finished = false
    private var callbackForwarded = false

    private val hardTimeout = Runnable {
        if (!finished && deadline.expired()) finish(ExtensionVerificationPanel.UNAVAILABLE)
    }

    private val fallbackProbe = object : Runnable {
        override fun run() {
            val view = web ?: return
            if (finished || callbackForwarded || !policy.allowsPage(view.url.orEmpty())) return
            // Read only the page's own fallback after it has been revealed; this
            // does not click or complete the verification challenge.
            view.evaluateJavascript(
                "(function(){var b=document.getElementById('fallback');" +
                    "var u=document.getElementById('fallbackUrl');" +
                    "return b&&b.getAttribute('data-shown')&&" +
                    "getComputedStyle(b).display!=='none'&&u?u.textContent:null;})()"
            ) { result ->
                val current = web ?: return@evaluateJavascript
                if (finished || callbackForwarded || !policy.allowsPage(current.url.orEmpty())) return@evaluateJavascript
                val callback = try { JSONTokener(result).nextValue() as? String } catch (_: Exception) { null }
                if (callback != null && policy.isBridgeMessageCandidate(current.url.orEmpty(), true, callback)) {
                    forwardCallback(Uri.parse(callback))
                } else {
                    mainHandler.postDelayed(this, 1000L)
                }
            }
        }
    }

    /** Returns false (nothing left behind) when the view could not be created. */
    fun start(): Boolean {
        val content = owner.findViewById<ViewGroup>(android.R.id.content) ?: return false
        val host = InvisibleVerificationLayer(owner)
        val view = try {
            NoFocusWebView(owner)
        } catch (_: Exception) {
            return false // Missing/updating WebView provider.
        }
        web = view
        layer = host
        view.apply {
            setBackgroundColor(Color.WHITE)
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            settings.setSupportMultipleWindows(false)
            settings.setNeedInitialFocus(false)
            CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
            webViewClient = object : WebViewClient() {
                override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                    if (request.isForMainFrame && !policy.allowsPage(request.url.toString())) {
                        fail()
                        return WebResourceResponse("text/plain", "UTF-8", ByteArrayInputStream(ByteArray(0)))
                    }
                    return null
                }
                override fun onPageStarted(view: WebView, target: String, favicon: android.graphics.Bitmap?) {
                    // POST/redirect navigations do not always call shouldOverrideUrlLoading.
                    if (!policy.allowsPage(target)) {
                        view.stopLoading()
                        fail()
                    }
                }
                override fun onPageFinished(view: WebView, target: String) {
                    if (policy.allowsPage(target)) {
                        mainHandler.removeCallbacks(fallbackProbe)
                        // The page reveals its fallback eight seconds after it
                        // verifies. Keep watching if verification takes longer.
                        mainHandler.postDelayed(fallbackProbe, 9000L)
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
                    fail()
                    return true
                }
                override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
                    handler.cancel(); fail()
                }
                override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                    if (request.isForMainFrame) fail()
                }
            }
        }
        host.addView(view, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        installReturnChannel(view)
        try {
            content.addView(host, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        } catch (_: Exception) {
            teardown()
            return false
        }
        host.clearFocus() // Never take focus from Flutter nor close the keyboard.
        deadline.start()
        mainHandler.postDelayed(hardTimeout, deadline.remainingMs())
        view.loadUrl(url)
        return true
    }

    /** Dart `close` / owner destroyed: silent, answers UNAVAILABLE. */
    fun cancel() = finish(ExtensionVerificationPanel.UNAVAILABLE)

    /** Never tear down inside a WebView callback: always post. */
    private fun fail() {
        mainHandler.post { finish(ExtensionVerificationPanel.UNAVAILABLE) }
    }

    /** Accept messages only from the exact HTTPS origin and the top-level frame. */
    private fun installReturnChannel(view: WebView): Boolean {
        val origin = policy.bridgeOriginRule() ?: return false
        return try {
            if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) return false
            WebViewCompat.addWebMessageListener(
                view, "MornyeGrant", setOf(origin),
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

    /**
     * Preserve the existing inbox and backend state/grant validation: the
     * callback still goes through MainActivity's intent handling. MainActivity
     * is already the top singleTask Activity, so this is delivered to
     * onNewIntent without switching Activities.
     */
    private fun forwardCallback(callback: Uri) {
        if (finished || callbackForwarded) return
        callbackForwarded = true
        try {
            owner.startActivity(Intent(owner, MainActivity::class.java)
                .setAction(Intent.ACTION_VIEW).setData(callback)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP))
            mainHandler.post { finish(ExtensionVerificationPanel.GRANTED) }
        } catch (_: Exception) {
            callbackForwarded = false
            fail()
        }
    }

    private fun finish(status: String) {
        if (finished) return
        finished = true
        deadline.markCompleted()
        teardown()
        onFinished(status)
    }

    private fun teardown() {
        mainHandler.removeCallbacksAndMessages(null)
        val host = layer
        val view = web
        layer = null
        web = null
        try {
            if (host != null) (host.parent as? ViewGroup)?.removeView(host)
            if (view != null) {
                view.stopLoading()
                (view.parent as? ViewGroup)?.removeView(view)
                view.removeAllViews()
                view.destroy()
            }
        } catch (_: Exception) {
            // Best effort: never let teardown break the main Activity.
        }
    }
}
