package xyz.luan.audioplayers.player

/** A lossy change to EQ or channel balance must never be applied silently. */
internal fun supportsMedia3Progressive(ordinaryMode: Boolean, equalizerEnabled: Boolean, balance: Float): Boolean =
    ordinaryMode && !equalizerEnabled && balance == 0f
