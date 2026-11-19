package com.zarz.mornye

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper

internal class BluetoothStartGuard(context: Context) {
    private val manager = context.getSystemService(AudioManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
        .build()
    private var keepAlive: AudioTrack? = null
    private val expire = Runnable { releaseKeepAlive() }

    fun routedToBluetooth(): Boolean {
        if (Build.VERSION.SDK_INT >= 33) {
            manager.getAudioDevicesForAttributes(attributes).firstOrNull()?.let { return it.type in bluetooth }
        }
        val outputs = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        if (outputs.any { it.type in preferred }) return false
        return outputs.any { it.type in bluetooth }
    }

    fun playSilence(durationMs: Int): Boolean {
        val millis = durationMs.coerceIn(50, 400)
        val track = silentTrack(millis) ?: return false
        return runCatching {
            track.play()
            main.postDelayed({ discard(track) }, millis + 250L)
            true
        }.getOrElse {
            discard(track)
            false
        }
    }

    fun setKeepAlive(enabled: Boolean, limitMs: Long): Boolean {
        val limit = limitMs.coerceIn(1_000L, 120_000L)
        if (!enabled) {
            releaseKeepAlive()
            return true
        }
        if (manager.mode != AudioManager.MODE_NORMAL) {
            releaseKeepAlive()
            return false
        }
        if (keepAlive != null) {
            main.removeCallbacks(expire)
            main.postDelayed(expire, limit)
            return true
        }
        val track = silentTrack(LOOP_MS) ?: return false
        return runCatching {
            track.setVolume(0f)
            track.setLoopPoints(0, SAMPLE_RATE * LOOP_MS / 1000, -1)
            track.play()
            keepAlive = track
            main.postDelayed(expire, limit)
            true
        }.getOrElse {
            discard(track)
            false
        }
    }

    fun release() = releaseKeepAlive()

    private fun releaseKeepAlive() {
        main.removeCallbacks(expire)
        keepAlive?.let(::discard)
        keepAlive = null
    }

    private fun silentTrack(millis: Int): AudioTrack? = runCatching {
        val bytes = SAMPLE_RATE * millis / 1000 * FRAME_BYTES
        val track = AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build(),
            )
            .setTransferMode(AudioTrack.MODE_STATIC)
            .setBufferSizeInBytes(bytes)
            .build()
        if (track.write(ByteArray(bytes), 0, bytes) == bytes) {
            track
        } else {
            track.release()
            null
        }
    }.getOrNull()

    private fun discard(track: AudioTrack) {
        runCatching { track.stop() }
        runCatching { track.release() }
    }

    private companion object {
        const val SAMPLE_RATE = 44_100
        const val FRAME_BYTES = 4
        const val LOOP_MS = 100

        val bluetooth = setOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_BLE_SPEAKER,
            AudioDeviceInfo.TYPE_BLE_BROADCAST,
            AudioDeviceInfo.TYPE_HEARING_AID,
        )
        val preferred = setOf(
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
        )
    }
}
