package com.fieldstudy.field_tms

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import java.util.concurrent.atomic.AtomicBoolean

/** User-visible, low-power recording; no notification action can desync Dart. */
class MotionRecordingService : Service() {
    private var foregroundError: String? = null

    override fun onCreate() {
        super.onCreate()
        try {
            val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= 26) {
                manager.createNotificationChannel(NotificationChannel(
                    CHANNEL, "Walking recording", NotificationManager.IMPORTANCE_LOW,
                ).apply { description = "Ongoing walking step recording" })
            }
            val open = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val content = PendingIntent.getActivity(
                this, 0, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL)
                else Notification.Builder(this)
            val notification = builder
                .setSmallIcon(android.R.drawable.ic_menu_compass)
                .setContentTitle("Field Stopwatch is recording steps")
                .setContentText("Open the app to pause walking recording.")
                .setContentIntent(content)
                .setCategory(Notification.CATEGORY_SERVICE)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build()
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_HEALTH)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {
            foregroundError = "Background walking recording could not start. Open the app and retry."
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val token = intent?.getLongExtra("request", -1L) ?: -1L
        val request = requests[token]
        if (request == null) {
            stopIfNotRunning()
            return START_NOT_STICKY
        }
        val runtime = MotionRuntime.get(this)
        val failure = foregroundError
        if (failure != null) {
            runtime.fail(failure) { value -> finish(token, value); stopSelf() }
        } else {
            runtime.start(request.sessionId, request.length, request.hasLength, request.cancelled::get) { value ->
                finish(token, value)
                stopIfNotRunning()
            }
        }
        // A killed process must be reviewed, not silently restarted as covered.
        return START_NOT_STICKY
    }

    private fun stopIfNotRunning() {
        MotionRuntime.get(this).read { if (it["status"] != "running") stopSelf() }
    }

    override fun onDestroy() {
        MotionRuntime.get(this).serviceDestroyed()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private data class Request(
        val sessionId: String,
        val length: Double?,
        val hasLength: Boolean,
        val cancelled: AtomicBoolean,
        val callback: (Map<String, Any?>) -> Unit,
    )

    companion object {
        private const val CHANNEL = "field_walking"
        private const val NOTIFICATION_ID = 7314
        private val requests = mutableMapOf<Long, Request>() // Main looper only.
        private var nextToken = 0L

        internal fun cancel(flag: AtomicBoolean) {
            requests.entries.removeAll { it.value.cancelled === flag }
        }

        internal fun start(
            context: Context,
            sessionId: String,
            length: Double?,
            hasLength: Boolean,
            cancelled: AtomicBoolean,
            callback: (Map<String, Any?>) -> Unit,
        ) {
            val token = ++nextToken
            requests[token] = Request(sessionId, length, hasLength, cancelled, callback)
            val intent = Intent(context, MotionRecordingService::class.java).putExtra("request", token)
            try {
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
                else context.startService(intent)
            } catch (_: Exception) {
                requests.remove(token)
                MotionRuntime.get(context).fail(
                    "Background walking recording could not start. Open the app and retry.", callback,
                )
            }
        }

        private fun finish(token: Long, value: Map<String, Any?>) {
            requests.remove(token)?.callback?.invoke(value)
        }
    }
}
