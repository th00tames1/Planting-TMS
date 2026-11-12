package com.fieldstudy.field_tms

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.hardware.Sensor
import android.hardware.SensorManager
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** All runtime prompts belong to first-launch preparation, never a field tap. */
class CapturePermissionsBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "field_tms/permissions")
    private var pending: MethodChannel.Result? = null
    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "prepare" -> {
                    val preferences = activity.getSharedPreferences("capture_permissions", 0)
                    if (pending != null) result.error("busy", "Permission preparation is already open.", null)
                    else if (preferences.getBoolean("prepared_v1", false)) result.success(null)
                    else {
                        val required = mutableListOf(
                            Manifest.permission.ACCESS_FINE_LOCATION,
                            Manifest.permission.ACCESS_COARSE_LOCATION,
                            Manifest.permission.RECORD_AUDIO,
                        )
                        if (Build.VERSION.SDK_INT >= 29 && (activity.getSystemService(Activity.SENSOR_SERVICE) as SensorManager).getDefaultSensor(Sensor.TYPE_STEP_COUNTER) != null) required += Manifest.permission.ACTIVITY_RECOGNITION
                        if (Build.VERSION.SDK_INT >= 33) required += Manifest.permission.POST_NOTIFICATIONS
                        val missing = required.filter { activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
                        // Remember the attempt even if the OS closes this process mid-dialog.
                        preferences.edit().putBoolean("prepared_v1", true).apply()
                        if (missing.isEmpty()) result.success(null)
                        else {
                            pending = result
                            try { activity.requestPermissions(missing.toTypedArray(), REQUEST) }
                            catch (_: Exception) { pending = null; result.success(null) }
                        }
                    }
                }
                "openSettings" -> {
                    try {
                        activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}")))
                        result.success(null)
                    } catch (_: Exception) { result.error("settings", "Open app permissions in your phone settings.", null) }
                }
                else -> result.notImplemented()
            }
        }
    }
    fun onPermissions(request: Int): Boolean {
        if (request != REQUEST) return false
        pending?.success(null); pending = null
        return true
    }
    fun dispose() { pending?.success(null); pending = null; channel.setMethodCallHandler(null) }
    companion object { private const val REQUEST = 7341 }
}
