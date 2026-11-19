package com.zarz.mornye

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.view.Surface
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

internal class TiltSensorStreamHandler(context: Context) :
    EventChannel.StreamHandler, SensorEventListener {

    private val appContext: Context = context.applicationContext
    private val sensorManager =
        appContext.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
    private val windowManager =
        appContext.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
    private var sink: EventChannel.EventSink? = null
    private var activeSensor: Sensor? = null

    private val rotation = FloatArray(9)
    private val baseRotation = FloatArray(9)
    private val angleChange = FloatArray(3)
    private var hasBase = false
    private var lastRotationNs = 0L
    private var centerPitch = 0.0
    private var centerRoll = 0.0
    private var integratedPitch = 0.0
    private var integratedRoll = 0.0
    private var lastTimestampNs = 0L
    private var smoothX = 0.0
    private var smoothY = 0.0
    private var hasSmooth = false
    private var lastEmitNs = 0L

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        stop()
        if (events == null) return
        val manager = sensorManager
        val sensor = manager?.let { pickSensor(it) }
        if (manager == null || sensor == null) {
            events.error("unavailable", "No motion sensor available", null)
            return
        }
        sink = events
        resetState()
        activeSensor = sensor
        val registered = manager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_GAME)
        if (!registered) {
            sink = null
            activeSensor = null
            events.error("unavailable", "Motion sensor could not be registered", null)
        }
    }

    override fun onCancel(arguments: Any?) {
        stop()
    }

    private fun stop() {
        sensorManager?.unregisterListener(this)
        sink = null
        activeSensor = null
        resetState()
    }

    private fun resetState() {
        hasBase = false
        lastRotationNs = 0L
        centerPitch = 0.0
        centerRoll = 0.0
        integratedPitch = 0.0
        integratedRoll = 0.0
        lastTimestampNs = 0L
        smoothX = 0.0
        smoothY = 0.0
        hasSmooth = false
        lastEmitNs = 0L
    }

    private fun pickSensor(manager: SensorManager): Sensor? =
        manager.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
            ?: manager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
            ?: manager.getDefaultSensor(Sensor.TYPE_GYROSCOPE)

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    override fun onSensorChanged(event: SensorEvent) {
        val target = sink ?: return
        var pitch: Double
        var roll: Double
        when (event.sensor.type) {
            Sensor.TYPE_GAME_ROTATION_VECTOR, Sensor.TYPE_ROTATION_VECTOR -> {
                SensorManager.getRotationMatrixFromVector(rotation, event.values)
                if (!hasBase) {
                    hasBase = true
                    System.arraycopy(rotation, 0, baseRotation, 0, 9)
                    lastRotationNs = event.timestamp
                    centerPitch = 0.0
                    centerRoll = 0.0
                }
                SensorManager.getAngleChange(angleChange, rotation, baseRotation)
                val rawPitch = wrapAngle(angleChange[1].toDouble())
                val rawRoll = wrapAngle(angleChange[2].toDouble())
                val dt = ((event.timestamp - lastRotationNs) / 1.0e9).coerceIn(0.0, 0.1)
                lastRotationNs = event.timestamp
                val follow = 1.0 - Math.exp(-dt / RECENTER_SECONDS)
                centerPitch += (rawPitch - centerPitch) * follow
                centerRoll += (rawRoll - centerRoll) * follow
                pitch = rawPitch - centerPitch
                roll = rawRoll - centerRoll
            }
            Sensor.TYPE_GYROSCOPE -> {
                val last = lastTimestampNs
                lastTimestampNs = event.timestamp
                if (last == 0L) return
                val dt = ((event.timestamp - last) / 1.0e9).coerceIn(0.0, 0.1)
                val leak = Math.exp(-dt / GYRO_LEAK_SECONDS)
                integratedPitch = integratedPitch * leak + event.values[0] * dt
                integratedRoll = integratedRoll * leak + event.values[1] * dt
                pitch = integratedPitch
                roll = integratedRoll
            }
            else -> return
        }
        when (screenRotation()) {
            Surface.ROTATION_90 -> {
                val turnedPitch = roll
                roll = -pitch
                pitch = turnedPitch
            }
            Surface.ROTATION_180 -> {
                pitch = -pitch
                roll = -roll
            }
            Surface.ROTATION_270 -> {
                val turnedPitch = -roll
                roll = pitch
                pitch = turnedPitch
            }
            else -> Unit
        }
        val x = deadZone((roll / MAX_RADIANS).coerceIn(-1.0, 1.0))
        val y = deadZone((-pitch / MAX_RADIANS).coerceIn(-1.0, 1.0))
        val now = event.timestamp
        if (hasSmooth) {
            val dt = ((now - lastEmitNs) / 1.0e9).coerceIn(0.0, 0.1)
            val blend = 1.0 - Math.exp(-dt / SMOOTHING_SECONDS)
            smoothX += (x - smoothX) * blend
            smoothY += (y - smoothY) * blend
        } else {
            smoothX = x
            smoothY = y
            hasSmooth = true
        }
        lastEmitNs = now
        target.success(listOf(smoothX, smoothY))
    }

    @Suppress("DEPRECATION")
    private fun screenRotation(): Int {
        return windowManager?.defaultDisplay?.rotation ?: Surface.ROTATION_0
    }

    private fun deadZone(value: Double): Double {
        val magnitude = Math.abs(value)
        if (magnitude <= DEAD_ZONE) return 0.0
        return Math.signum(value) * (magnitude - DEAD_ZONE) / (1.0 - DEAD_ZONE)
    }

    private fun wrapAngle(value: Double): Double {
        var angle = value
        while (angle > Math.PI) angle -= 2 * Math.PI
        while (angle < -Math.PI) angle += 2 * Math.PI
        return angle
    }

    companion object {
        const val CHANNEL = "musa/tilt"
        private const val MAX_RADIANS = 26.0 * Math.PI / 180.0
        private const val SMOOTHING_SECONDS = 0.04
        private const val DEAD_ZONE = 0.04
        private const val GYRO_LEAK_SECONDS = 1.5
        private const val RECENTER_SECONDS = 7.0

        fun register(context: Context, messenger: BinaryMessenger) {
            EventChannel(messenger, CHANNEL).setStreamHandler(TiltSensorStreamHandler(context))
        }
    }
}
