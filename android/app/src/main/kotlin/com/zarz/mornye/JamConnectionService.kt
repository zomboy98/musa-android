package com.zarz.mornye

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.EventChannel

/** A successful lease callback means that startForeground actually returned. */
class JamConnectionService : Service() {
    companion object {
        private const val CHANNEL = "jam_connection"
        private const val ID = 0x4D4A0001
        private val handler = Handler(Looper.getMainLooper())
        private var lease: String? = null
        private val pending = JamLeaseCallbacks()
        private var foreground = false
        var events: EventChannel.EventSink? = null

        private fun completePending(value: Boolean) {
            pending.complete(value)
        }

        fun start(context: Context, token: String, done: (Boolean) -> Unit) {
            if (lease != null && lease != token) { done(false); return }
            if (lease == token) {
                if (foreground) done(true) else pending.add(done)
                return
            }
            lease = token
            pending.add(done)
            try {
                val intent = Intent(context, JamConnectionService::class.java).putExtra("lease", token)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent)
                else context.startService(intent)
                handler.postDelayed({
                    if (lease == token && pending.isNotEmpty()) {
                        lease = null
                        completePending(false)
                        context.stopService(Intent(context, JamConnectionService::class.java))
                    }
                }, 10000)
            } catch (e: Exception) {
                if (lease == token) { lease = null; completePending(false) }
            }
        }
        fun stop(context: Context, token: String) {
            if (lease != token) return
            lease = null
            foreground = false
            completePending(false)
            context.stopService(Intent(context, JamConnectionService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null
    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "MUSA Jam", NotificationManager.IMPORTANCE_LOW)
            )
        }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            val notification = NotificationCompat.Builder(this, CHANNEL)
                .setContentTitle("MUSA Jam")
                .setContentText("Jam session active")
                .setSmallIcon(R.drawable.ic_notification_airplay)
                .setContentIntent(mainActivityContentIntent())
                .setOngoing(true).setOnlyAlertOnce(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setCategory(NotificationCompat.CATEGORY_SERVICE).build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            else startForeground(ID, notification)
            if (lease == null || intent?.getStringExtra("lease") != lease) {
                stopSelf(startId)
            } else {
                foreground = true
                completePending(true)
            }
        } catch (e: Exception) {
            foreground = false
            lease = null
            completePending(false)
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }
    override fun onDestroy() {
        // A new start may already be queued after an explicit stop.
        val unexpected = foreground
        foreground = false
        if (unexpected) {
            val lost = lease
            lease = null
            completePending(false)
            if (lost != null) events?.success(lost)
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
