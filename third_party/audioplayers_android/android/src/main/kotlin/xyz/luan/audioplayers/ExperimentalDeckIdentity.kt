package xyz.luan.audioplayers

import java.util.concurrent.atomic.AtomicBoolean

/** Private object identity; never serialized or exposed through a method channel. */
internal class ExperimentalDeckIdentity(private val target: Any, private val epoch: Int) {
    private val live = AtomicBoolean(true)
    fun valid(current: Any?, currentEpoch: Int): Boolean = live.get() && current === target && epoch == currentEpoch
    fun close(): Boolean = live.compareAndSet(true, false)
}
