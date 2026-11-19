package com.zarz.mornye

/** Coordinates a late native cancellation registration with WorkManager stop. */
internal class SessionStopGate {
    private var stopped = false
    private var cancel: (() -> Unit)? = null
    @Synchronized fun register(action: () -> Unit): Boolean {
        if (stopped) return false
        check(cancel == null)
        cancel = action
        return true
    }
    @Synchronized fun clear() { cancel = null }
    @Synchronized fun stop() {
        if (stopped) return
        stopped = true
        val action = cancel
        cancel = null
        action?.invoke()
    }
}
