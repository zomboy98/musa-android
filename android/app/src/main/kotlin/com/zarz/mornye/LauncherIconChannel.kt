package com.zarz.mornye

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

private val launcherIcons = linkedMapOf(
    "original" to "LauncherOriginal",
    "chrome" to "LauncherChrome",
    "brushed" to "LauncherBrushed",
    "glass" to "LauncherGlass",
    "neon" to "LauncherNeon",
    "pearl" to "LauncherPearl",
)

/** The actual PackageManager state is authoritative, including after an upgrade. */
internal fun MainActivity.registerLauncherIconChannel(messenger: BinaryMessenger) {
    val pm = packageManager
    fun component(id: String) = ComponentName(packageName, "com.zarz.mornye.${launcherIcons.getValue(id)}")
    fun enabled(id: String): Boolean = when (pm.getComponentEnabledSetting(component(id))) {
        PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
        PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> id == "original"
        else -> false
    }
    fun setSelected(id: String) {
        require(id in launcherIcons)
        val before = launcherIcons.keys.filter(::enabled)
        if (before.size == 1 && before.single() == id) return
        val flags = PackageManager.DONT_KILL_APP
        val on = PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        val off = PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        if (Build.VERSION.SDK_INT >= 33) {
            pm.setComponentEnabledSettings(launcherIcons.keys.map {
                PackageManager.ComponentEnabledSetting(component(it), if (it == id) on else off, flags)
            })
        } else {
            // Enable first: a failed second operation leaves a working launcher entry.
            pm.setComponentEnabledSetting(component(id), on, flags)
            try {
                launcherIcons.keys.filter { it != id }.forEach {
                    pm.setComponentEnabledSetting(component(it), off, flags)
                }
            } catch (error: RuntimeException) {
                // Best effort recovery leaves at least the selected entry available.
                before.forEach { pm.setComponentEnabledSetting(component(it), on, flags) }
                throw error
            }
        }
        check(launcherIcons.keys.filter(::enabled) == listOf(id)) { "Launcher state did not converge" }
    }
    MethodChannel(messenger, "musa/launcher_icon").setMethodCallHandler { call, result ->
        try {
            when (call.method) {
                "get" -> {
                    val active = launcherIcons.keys.filter(::enabled)
                    if (active.size != 1) setSelected(active.firstOrNull() ?: "original")
                    result.success(launcherIcons.keys.single(::enabled))
                }
                "set" -> {
                    val id = call.argument<String>("id") ?: throw IllegalArgumentException("Missing icon")
                    setSelected(id)
                    result.success(id)
                }
                // Ringer mode: 0 silent, 1 vibrate, 2 normal. The welcome video
                // stays mute unless it is normal (it never asks for audio focus).
                "ringer" -> {
                    val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    result.success(audio.ringerMode)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("launcher_icon", error.message, null)
        }
    }
}
