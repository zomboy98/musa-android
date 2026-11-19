package xyz.luan.audioplayers.player

/** All methods run on the owning player's looper. */
internal interface Media3SessionEffect {
    fun configure(config: Map<String, Any?>)
    fun close()
}

/** Capability ownership is independent of the plugin's mutable deck registry. */
internal class Media3EqOptInOwner {
    private val owner = java.util.concurrent.atomic.AtomicReference<Any?>(null)
    fun enable(token: Any): Boolean = owner.compareAndSet(null, token) || owner.get() === token
    fun revoke(token: Any) { owner.compareAndSet(token, null) }
    fun enabled(): Boolean = owner.get() != null
    fun enabledFor(token: Any?): Boolean = token != null && owner.get() === token
}

/** Manages only the effect attached to this player's current nonzero session. */
internal class Media3EffectSessionController(private val factory: (Int) -> Media3SessionEffect) {
    private var generation = Long.MIN_VALUE
    private var session = 0
    private var desired: Map<String, Any?> = emptyMap()
    private var effect: Media3SessionEffect? = null
    private var released = false
    private var closeFailed = false

    /** True only after the desired effect was configured on a valid session (or disabled). */
    fun configureConfirmed(configuration: Map<String, Any?>): Boolean {
        if (released) return false
        configure(configuration)
        return desired["enabled"] != true || (session > 0 && effect != null)
    }

    fun onSessionConfirmed(id: Int, eventGeneration: Long): Boolean {
        if (released || eventGeneration < generation) return false
        onSession(id, eventGeneration)
        return desired["enabled"] != true || (session > 0 && effect != null)
    }

    fun configure(configuration: Map<String, Any?>) {
        if (released) return
        check(!closeFailed) { "Previous equalizer close was not confirmed" }
        desired = configuration.toMap()
        if (desired["enabled"] != true) { closeEffect(); return }
        applyDesired()
    }

    fun onSession(id: Int, eventGeneration: Long) {
        if (released || eventGeneration < generation) return
        check(!closeFailed) { "Previous equalizer close was not confirmed" }
        if (generation != Long.MIN_VALUE && eventGeneration > generation) {
            closeEffect()
            session = 0
        }
        generation = eventGeneration
        val valid = id.takeIf { it > 0 } ?: 0
        if (session != valid) { closeEffect(); session = valid }
        if (desired["enabled"] == true && effect == null) applyDesired()
    }

    private fun applyDesired() {
        if (session <= 0) return
        val target = effect ?: factory(session).also { effect = it }
        try { target.configure(desired) }
        catch (error: Exception) { try { closeEffect() } catch (_: Exception) {} ; throw error }
    }

    private fun closeEffect() {
        val old = effect
        effect = null
        try { old?.close() } catch (error: Exception) { closeFailed = true; throw error }
    }

    fun release() {
        if (released) return
        released = true
        check(!closeFailed) { "Previous equalizer close was not confirmed" }
        closeEffect()
    }
}
