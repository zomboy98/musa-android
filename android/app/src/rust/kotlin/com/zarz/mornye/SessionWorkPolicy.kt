package com.zarz.mornye

import java.util.concurrent.Future
import java.util.concurrent.TimeUnit

internal fun reportSessionRescheduleFailure(enqueued: Boolean, stopped: Boolean): Boolean = !enqueued && !stopped

internal fun awaitSessionWorkOperation(result: Future<*>, timeoutMs: Long): Boolean = try {
    result.get(timeoutMs, TimeUnit.MILLISECONDS)
    true
} catch (_: InterruptedException) {
    Thread.currentThread().interrupt()
    false
} catch (_: Exception) { false }

internal fun validSessionWorkId(id: String): Boolean =
    id.length in 1..128 && id.matches(Regex("[a-z0-9][a-z0-9._-]*"))

internal data class SessionWorkPlan(val delay: Long, val expiry: Long, val attempts: Int)

internal fun initialSessionWork(status: String, expiresAt: Long?, now: Long): SessionWorkPlan? {
    if (status != "valid_until" && status != "refreshed") return null
    val expiry = expiresAt ?: return null
    if (expiry <= now) return null
    val delay = (expiry - now - 30 * 60_000L).coerceAtLeast(0)
    return SessionWorkPlan(delay, expiry, 0)
}

internal fun nextSessionWork(status: String, resultExpiry: Long?, previousExpiry: Long, attempts: Int, now: Long): SessionWorkPlan? {
    if (status !in setOf("valid_until", "refreshed", "unavailable")) return null
    if (status != "unavailable" && (resultExpiry == null || resultExpiry <= now)) return null
    val expiry = if (status == "unavailable") previousExpiry else resultExpiry!!
    if (expiry <= now) return null
    val normal = expiry - now - 30 * 60_000L
    if (normal > 0) return SessionWorkPlan(normal, expiry, 0)
    val advanced = status == "refreshed" && expiry > previousExpiry
    if (!advanced && attempts >= 3) return null
    val delay = minOf(300_000L, (expiry - now) / 2)
    if (delay <= 0) return null
    return SessionWorkPlan(delay, expiry, if (advanced) 0 else attempts + 1)
}
