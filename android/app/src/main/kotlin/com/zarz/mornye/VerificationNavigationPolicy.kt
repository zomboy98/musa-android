package com.zarz.mornye

import java.net.URI
import java.net.URLDecoder

/** Top-level navigation only; embedded challenge resources retain normal HTTPS loading. */
internal class VerificationNavigationPolicy(initialUrl: String) {
    private val initial = parse(initialUrl)
    private val expectedState = initial?.let { callbackState(it) }
    val valid = initial?.let(::isHttps) == true

    /** Exact HTTPS origin exposed to the WebView messaging API; never a wildcard. */
    fun bridgeOriginRule(): String? {
        val origin = initial ?: return null
        if (!valid) return null
        return try {
            URI("https", null, origin.host, origin.port, null, null, null).toASCIIString()
        } catch (_: Exception) { null }
    }

    fun allowsPage(url: String): Boolean {
        val candidate = parse(url) ?: return false
        val origin = initial ?: return false
        return valid && isHttps(candidate) &&
            candidate.host.equals(origin.host, ignoreCase = true) &&
            port(candidate) == port(origin)
    }

    // This is not an authorization decision. The existing native inbox and
    // backend must validate state, ownership and the one-time grant.
    fun isCallbackCandidate(url: String): Boolean {
        val candidate = parse(url) ?: return false
        if (!candidate.scheme.equals("mornye", true) || candidate.userInfo != null ||
            candidate.host?.lowercase(java.util.Locale.US) !in setOf("session-grant", "musa-session-grant")) return false
        val query = try {
            candidate.rawQuery.orEmpty().split('&').map {
                val parts = it.split('=', limit = 2)
                URLDecoder.decode(parts[0], "UTF-8") to
                    URLDecoder.decode(parts.getOrElse(1) { "" }, "UTF-8").trim()
            }
        } catch (_: Exception) { return false }
        if (query.map { it.first }.toSet().size != query.size) return false
        val params = query.toMap()
        val state = params["state"].orEmpty()
        val grant = (params["grant"] ?: params["code"]).orEmpty()
        return expectedState != null && state == expectedState && state.length <= 4096 &&
            grant.isNotEmpty() && grant.length <= 16384
    }

    /** The page may only deliver the full callback from its top-level origin. */
    fun isBridgeMessageCandidate(origin: String, mainFrame: Boolean, message: String): Boolean =
        mainFrame && message.length <= 32768 && allowsPage(origin) && isCallbackCandidate(message)

    private fun callbackState(uri: URI, depth: Int = 0): String? {
        if (depth > 3) return null
        val params = try {
            uri.rawQuery.orEmpty().split('&').associate {
                val parts = it.split('=', limit = 2)
                URLDecoder.decode(parts[0], "UTF-8") to URLDecoder.decode(parts.getOrElse(1) { "" }, "UTF-8").trim()
            }
        } catch (_: Exception) { return null }
        params["state"]?.takeIf { it.isNotEmpty() }?.let { return it }
        for (key in listOf("cb", "callback", "callback_url", "redirect_uri")) {
            val nested = params[key]?.let(::parse) ?: continue
            callbackState(nested, depth + 1)?.let { return it }
        }
        return null
    }

    private fun parse(url: String): URI? = try { URI(url) } catch (_: Exception) { null }
    private fun isHttps(uri: URI) = uri.scheme.equals("https", true) &&
        !uri.host.isNullOrBlank() && uri.userInfo == null
    private fun port(uri: URI) = if (uri.port == -1) 443 else uri.port
}
