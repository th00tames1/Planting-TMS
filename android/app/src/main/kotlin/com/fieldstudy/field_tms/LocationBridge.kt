package com.fieldstudy.field_tms

import android.Manifest
import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.*
import android.provider.Settings
import io.flutter.plugin.common.*
import java.util.UUID

/** Cached fixes only: the Dart gesture boundary never waits for a GPS request. */
class LocationBridge(private val activity: Activity, messenger: BinaryMessenger) : EventChannel.StreamHandler {
    private val methods = MethodChannel(messenger, "field_tms/location")
    private val events = EventChannel(messenger, "field_tms/location_events")
    private var pending: MethodChannel.Result? = null
    private var wanted = false
    init {
        events.setStreamHandler(this)
        methods.setMethodCallHandler { call, result ->
            when (call.method) {
                "clockInfo" -> result.success(mapOf("bootId" to bootId(activity)))
                "enable" -> {
                    wanted = true
                    if (pending != null) result.error("busy", "Location permission is already open.", null)
                    else if (!hasPermission(activity) && Build.VERSION.SDK_INT >= 23) {
                        pending = result
                        activity.requestPermissions(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION,
                            Manifest.permission.ACCESS_COARSE_LOCATION), REQUEST)
                    } else { start(); result.success(LocationRuntime.snapshot) }
                }
                "start" -> { wanted = true; start(); result.success(LocationRuntime.snapshot) }
                "stop" -> {
                    wanted = false
                    activity.stopService(Intent(activity, LocationRecordingService::class.java))
                    LocationRuntime.publish(mapOf("status" to "off"))
                    result.success(LocationRuntime.snapshot)
                }
                else -> result.notImplemented()
            }
        }
    }
    private fun start() {
        if (!hasPermission(activity)) {
            LocationRuntime.publish(mapOf("status" to "permission_required")); return
        }
        try {
            val intent = Intent(activity, LocationRecordingService::class.java)
            if (Build.VERSION.SDK_INT >= 26) activity.startForegroundService(intent) else activity.startService(intent)
            LocationRuntime.publish(mapOf("status" to "waiting"))
        } catch (_: Exception) { LocationRuntime.publish(mapOf("status" to "error")) }
    }
    fun onPermissions(requestCode: Int): Boolean {
        if (requestCode != REQUEST) return false
        val reply = pending
        pending = null
        if (wanted && hasPermission(activity)) start() else LocationRuntime.publish(mapOf("status" to if (wanted) "denied" else "off"))
        reply?.success(LocationRuntime.snapshot)
        return true
    }
    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        LocationRuntime.sink = sink
        sink.success(LocationRuntime.snapshot)
    }
    override fun onCancel(arguments: Any?) { LocationRuntime.sink = null }
    fun dispose() {
        pending?.error("closed", "Location permission request was interrupted.", null)
        pending = null
        LocationRuntime.sink = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }
    companion object {
        const val REQUEST = 7321
        fun hasPermission(context: Context): Boolean = Build.VERSION.SDK_INT < 23 ||
            context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        private val fallbackBoot = "process-${UUID.randomUUID()}"
        fun bootId(context: Context): String = try {
            if (Build.VERSION.SDK_INT >= 24) "android-${Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT)}"
            else fallbackBoot
        } catch (_: Exception) { fallbackBoot }
    }
}

internal object LocationRuntime {
    private val publisher = UUID.randomUUID().toString()
    private var serial = 0L
    var snapshot: Map<String, Any?> = mapOf("status" to "off", "publisher" to publisher, "serial" to serial)
    var sink: EventChannel.EventSink? = null
    fun publish(value: Map<String, Any?>) {
        snapshot = value + mapOf("publisher" to publisher, "serial" to ++serial)
        sink?.success(snapshot)
    }
}

/** Location is independent of step-sensor availability. No wake lock or raw
 * IMU polling. A five-second GPS request runs only for a user-started study. */
class LocationRecordingService : Service(), LocationListener {
    private lateinit var manager: LocationManager
    override fun onCreate() {
        super.onCreate()
        manager = getSystemService(LOCATION_SERVICE) as LocationManager
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            val notifications = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= 26) notifications.createNotificationChannel(
                NotificationChannel("field_location", "Study location", NotificationManager.IMPORTANCE_LOW))
            val open = PendingIntent.getActivity(this, 7321, Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "field_location") else Notification.Builder(this)
            val notice = builder.setSmallIcon(android.R.drawable.ic_menu_mylocation)
                .setContentTitle("Field Stopwatch is recording location")
                .setContentText("Location is saved at each activity boundary. Stop in the app.")
                .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true).build()
            if (Build.VERSION.SDK_INT >= 29) startForeground(7321, notice, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
            else startForeground(7321, notice)
            manager.removeUpdates(this)
            var registered = false
            // Outdoor study positions use GNSS. Do not simultaneously request
            // a network-provider stream; measurement has no app network client.
            for (provider in listOf(LocationManager.GPS_PROVIDER)) {
                if (!manager.isProviderEnabled(provider)) continue
                try {
                    manager.getLastKnownLocation(provider)?.let { onLocationChanged(it) }
                    manager.requestLocationUpdates(provider, 5000L, 0f, this, Looper.getMainLooper())
                    registered = true
                } catch (_: SecurityException) { /* Approximate-only permission may exclude GPS. */ }
            }
            if (!registered) { LocationRuntime.publish(mapOf("status" to "disabled")); stopSelf() }
        } catch (_: Exception) {
            LocationRuntime.publish(mapOf("status" to "error")); stopSelf()
        }
        return START_NOT_STICKY
    }
    override fun onLocationChanged(fix: Location) {
        if (!fix.hasAccuracy() || fix.accuracy < 0) return
        val previous = LocationRuntime.snapshot["fixMonoMs"] as? Long
        val mono = fix.elapsedRealtimeNanos / 1_000_000L
        if (previous != null && mono < previous) return
        LocationRuntime.publish(mapOf("status" to "fresh", "latitude" to fix.latitude,
            "longitude" to fix.longitude, "accuracyM" to fix.accuracy.toDouble(),
            "fixUtc" to java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", java.util.Locale.US).apply {
                timeZone = java.util.TimeZone.getTimeZone("UTC")
            }.format(java.util.Date(fix.time)), "fixMonoMs" to mono,
            "provider" to fix.provider,
            "mock" to (if (Build.VERSION.SDK_INT >= 31) fix.isMock else fix.isFromMockProvider)))
    }
    override fun onProviderDisabled(provider: String) { LocationRuntime.publish(mapOf("status" to "disabled")) }
    override fun onProviderEnabled(provider: String) { LocationRuntime.publish(mapOf("status" to "waiting")) }
    @Deprecated("Deprecated in Android")
    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
    override fun onDestroy() {
        try { manager.removeUpdates(this) } catch (_: Exception) { }
        LocationRuntime.publish(mapOf("status" to "off"))
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}
