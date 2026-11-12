package com.fieldstudy.field_tms

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import org.json.JSONObject

/** One serialized sensor/state owner, independent of the Flutter engine lifetime. */
internal class MotionRuntime private constructor(context: Context) : SensorEventListener {
    private val app = context.applicationContext
    private val thread = HandlerThread("FieldWalkingSteps").apply { start() }
    private val worker = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())
    // Worker-thread owned and deliberately not restored from durable state.
    private val observationOrder = ObservationOrder()
    private val preferences = app.getSharedPreferences("field_walking_v1", Context.MODE_PRIVATE)
    private val sensors = app.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private var sensor: Sensor? = null
    private var registered = false
    private var sessionId: String? = null
    private var status = "idle"
    private var canReplaceSession = true
    private var stepLengthM: Double? = null
    private var accumulator = StepAccumulator()
    private var message: String? = null
    private var observedAtEpochMs = 0L
    private var lastPersistMs = 0L
    private var persistQueued = false
    private var emitQueued = false
    private var lastEmitMs = 0L
    private val listeners = mutableMapOf<Any, (Map<String, Any?>) -> Unit>()
    private val saveTask = Runnable {
        persistQueued = false
        persist()
    }
    private val emitTask = Runnable {
        emitQueued = false
        emitNow()
    }

    init { worker.post { restore() } }

    fun read(callback: (Map<String, Any?>) -> Unit) = worker.post {
        refreshPermission()
        deliver(callback)
    }

    fun subscribe(token: Any, listener: (Map<String, Any?>) -> Unit) = worker.post {
        listeners[token] = listener
        val value = snapshot()
        main.post { listener(value) }
    }

    fun unsubscribe(token: Any) = worker.post { listeners.remove(token) }

    fun preflight(id: String, callback: (Map<String, Any?>?) -> Unit) = worker.post {
        val error = startError(id)
        val value = error?.let { snapshot("error", it) }
        main.post { callback(value) }
    }

    fun start(
        id: String,
        length: Double?,
        hasLength: Boolean,
        cancelled: () -> Boolean = { false },
        callback: (Map<String, Any?>) -> Unit,
    ) = worker.post {
        val conflict = startError(id)
        if (conflict != null) {
            deliver(callback, snapshot("error", conflict))
            return@post
        }
        if (hasLength && !validLength(length)) {
            deliver(callback, snapshot("error", "Step length must be a positive finite number."))
            return@post
        }
        if (status == "running" && hasLength && length != stepLengthM) {
            deliver(callback, snapshot("error", "Pause walking recording before changing step length."))
            return@post
        }
        if (id != sessionId) {
            accumulator = StepAccumulator()
            sessionId = id
            observedAtEpochMs = 0L
        }
        if (hasLength) stepLengthM = length
        if (cancelled()) {
            canReplaceSession = true
            pausePreservingAvailability()
        } else if (sensor == null) {
            canReplaceSession = false
            stopWithStatus("unavailable", "This device has no step counter sensor.")
        } else if (!hasMotionPermission(app)) {
            canReplaceSession = false
            stopWithStatus("permissionDenied", "Walking permission is not granted.")
        } else if (status != "running") {
            canReplaceSession = false
            accumulator.resume(SystemClock.elapsedRealtimeNanos())
            status = "running"
            message = "Waiting for a fresh step baseline."
            try {
                registered = sensors.registerListener(
                    this, sensor, SensorManager.SENSOR_DELAY_NORMAL, 5_000_000, worker,
                )
                if (!registered) stopWithStatus("error", "The step counter could not start.")
            } catch (_: SecurityException) {
                stopWithStatus("permissionDenied", "Walking permission is not granted.")
            } catch (_: Exception) {
                stopWithStatus("error", "The step counter could not start.")
            }
        }
        persist()
        emitNow()
        deliver(callback)
    }

    fun permissionDenied(
        id: String,
        length: Double?,
        hasLength: Boolean,
        callback: (Map<String, Any?>) -> Unit,
    ) = worker.post {
        val conflict = startError(id)
        if (conflict != null) {
            deliver(callback, snapshot("error", conflict))
            return@post
        }
        if (id != sessionId) {
            sessionId = id
            accumulator = StepAccumulator()
            observedAtEpochMs = 0L
        }
        if (hasLength && validLength(length)) stepLengthM = length
        canReplaceSession = false
        stopWithStatus("permissionDenied", "Walking permission is not granted.")
        persist()
        emitNow()
        deliver(callback)
    }

    fun pause(id: String, callback: (Map<String, Any?>) -> Unit) = worker.post {
        if (id != sessionId) {
            deliver(callback, snapshot("error", "The walking session does not match."))
            return@post
        }
        canReplaceSession = true
        pausePreservingAvailability()
        persist()
        emitNow()
        stopService()
        deliver(callback)
    }

    fun cancelPending(id: String, callback: (Map<String, Any?>) -> Unit) = worker.post {
        val conflict = startError(id)
        if (conflict != null) {
            deliver(callback, snapshot("error", conflict))
            return@post
        }
        if (sessionId != id) {
            sessionId = id
            accumulator = StepAccumulator()
            observedAtEpochMs = 0L
        }
        canReplaceSession = true
        pausePreservingAvailability()
        persist()
        emitNow()
        stopService()
        deliver(callback)
    }

    fun setStepLength(length: Double?, callback: (Map<String, Any?>) -> Unit) = worker.post {
        if (status == "running") {
            deliver(callback, snapshot("error", "Pause walking recording before changing step length."))
            return@post
        }
        if (!validLength(length)) {
            deliver(callback, snapshot("error", "Step length must be a positive finite number."))
            return@post
        }
        stepLengthM = length
        persist()
        emitNow()
        deliver(callback)
    }

    fun fail(text: String, callback: ((Map<String, Any?>) -> Unit)? = null) = worker.post {
        accumulator.markGap()
        stopWithStatus("error", text)
        persist()
        emitNow()
        if (callback != null) deliver(callback)
        stopService()
    }

    fun serviceDestroyed() = worker.post {
        if (status == "running") {
            accumulator.markGap()
            canReplaceSession = true
            stopWithStatus("paused", "Walking recording was interrupted. Resume to continue.")
            persist()
            emitNow()
        }
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (status != "running" || !registered || event.sensor.type != Sensor.TYPE_STEP_COUNTER) return
        val raw = event.values.firstOrNull()?.toDouble()
        val nowNs = SystemClock.elapsedRealtimeNanos()
        if (raw == null || !raw.isFinite() || raw < 0 || raw > Long.MAX_VALUE.toDouble() ||
            raw % 1.0 != 0.0 || event.timestamp > nowNs + 1_000_000_000L) {
            accumulator.markGap()
            message = "An invalid step reading was omitted."
        } else if (!accumulator.accept(raw.toLong(), event.timestamp)) {
            return
        } else {
            message = when {
                accumulator.gap -> "Some steps near recording boundaries may be omitted."
                stepLengthM == null -> "Set a measured step length to estimate distance."
                else -> null
            }
            val ageMs = ((SystemClock.elapsedRealtimeNanos() - event.timestamp) / 1_000_000L)
                .coerceAtLeast(0)
            observedAtEpochMs = System.currentTimeMillis() - ageMs
        }
        schedulePersist()
        scheduleEmit()
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private fun restore() {
        sensor = try {
            sensors.getDefaultSensor(Sensor.TYPE_STEP_COUNTER, true)
                ?: sensors.getDefaultSensor(Sensor.TYPE_STEP_COUNTER)
        } catch (_: Exception) { null }
        try {
            val raw = preferences.getString("state", null) ?: return
            val saved = JSONObject(raw)
            sessionId = if (saved.isNull("sessionId")) null else saved.getString("sessionId").ifBlank { null }
            status = saved.optString("status", "idle")
            canReplaceSession = saved.optBoolean("canReplaceSession", status == "paused" || status == "idle")
            if (status !in setOf("running", "paused", "idle", "permissionDenied", "unavailable", "error") ||
                (sessionId?.length ?: 0) > 128) throw IllegalStateException("Invalid session")
            stepLengthM = if (saved.isNull("stepLengthM")) null else saved.getDouble("stepLengthM")
            if (!validLength(stepLengthM)) throw IllegalStateException("Invalid step length")
            val savedSteps = saved.getLong("steps")
            if (savedSteps < 0) throw IllegalStateException("Invalid steps")
            val restarted = saved.optInt("bootCount", -1) != bootCount()
            val interrupted = status == "running"
            accumulator = StepAccumulator(savedSteps, saved.optBoolean("gap") || restarted || interrupted)
            observedAtEpochMs = saved.optLong("observedAtEpochMs", 0)
            message = if (saved.isNull("message")) null else saved.optString("message")
            if (interrupted || restarted) {
                canReplaceSession = true
                status = if (sessionId == null) "idle" else "paused"
                message = if (restarted) "Device restarted. Walking coverage has a gap."
                    else "Walking recording was interrupted. Resume to continue."
                persist()
            }
        } catch (_: Exception) {
            sessionId = null
            stepLengthM = null
            observedAtEpochMs = 0L
            status = "error"
            accumulator = StepAccumulator(initialGap = true)
            message = "Saved walking data could not be read."
        }
    }

    private fun startError(id: String): String? = when {
        id.isBlank() || id.length > 128 -> "A valid walking session is required."
        sessionId != null && id != sessionId && !canReplaceSession ->
            "Pause the current walking session before starting another."
        else -> null
    }

    private fun stopWithStatus(next: String, text: String?) {
        if (registered) sensors.unregisterListener(this)
        registered = false
        accumulator.pause()
        status = next
        message = text
    }

    private fun pausePreservingAvailability() {
        val next = MotionRules.pausedStatus(status, sensor != null, hasMotionPermission(app))
        val text = when {
            next == status && next != "running" -> message
            next == "unavailable" -> "This device has no step counter sensor."
            next == "permissionDenied" -> "Walking permission is not granted."
            else -> null
        }
        stopWithStatus(next, text)
    }

    private fun refreshPermission() {
        if (status == "running" && !hasMotionPermission(app)) {
            accumulator.markGap()
            stopWithStatus("permissionDenied", "Walking permission was revoked.")
            persist()
            emitNow()
            stopService()
        }
    }

    private fun schedulePersist() {
        if (persistQueued) return
        persistQueued = true
        worker.postDelayed(saveTask, (5_000 - (SystemClock.elapsedRealtime() - lastPersistMs)).coerceAtLeast(0))
    }

    private fun persist() {
        worker.removeCallbacks(saveTask)
        persistQueued = false
        val value = JSONObject().apply {
            put("sessionId", sessionId ?: JSONObject.NULL)
            put("status", status)
            put("canReplaceSession", canReplaceSession)
            put("steps", accumulator.steps)
            put("stepLengthM", stepLengthM ?: JSONObject.NULL)
            put("gap", accumulator.gap)
            put("observedAtEpochMs", observedAtEpochMs)
            put("message", message ?: JSONObject.NULL)
            put("bootCount", bootCount())
        }
        val saved = try {
            preferences.edit().putString("state", value.toString()).commit()
        } catch (_: Exception) { false }
        if (!saved) {
            stopWithStatus("error", "Walking data could not be saved. Recording is paused.")
            accumulator.markGap()
            emitNow()
            stopService()
        }
        lastPersistMs = SystemClock.elapsedRealtime()
    }

    private fun scheduleEmit() {
        if (emitQueued) return
        emitQueued = true
        worker.postDelayed(emitTask, (1_000 - (SystemClock.elapsedRealtime() - lastEmitMs)).coerceAtLeast(0))
    }

    private fun emitNow() {
        worker.removeCallbacks(emitTask)
        emitQueued = false
        lastEmitMs = SystemClock.elapsedRealtime()
        val value = snapshot()
        val targets = listeners.values.toList()
        main.post { targets.forEach { it(value) } }
    }

    private fun snapshot(overrideStatus: String? = null, overrideMessage: String? = null): Map<String, Any?> {
        val order = observationOrder.next()
        val finalStatus = overrideStatus ?: if (sensor == null) "unavailable" else status
        return mapOf(
            "sessionId" to sessionId,
            "status" to finalStatus,
            "steps" to accumulator.steps,
            "distanceM" to MotionRules.distance(finalStatus, sensor != null, accumulator.steps, stepLengthM),
            "stepLengthM" to stepLengthM,
            "source" to if (sensor == null) "unavailable" else "android_step_counter",
            "estimated" to true,
            "observedAtEpochMs" to observedAtEpochMs,
            "observationEpoch" to order.epoch,
            "observationSequence" to order.sequence,
            "gap" to accumulator.gap,
            "message" to (overrideMessage ?: message ?: if (sensor == null) "This device has no step counter sensor." else null),
        )
    }

    private fun deliver(callback: (Map<String, Any?>) -> Unit, value: Map<String, Any?> = snapshot()) {
        main.post { callback(value) }
    }

    private fun stopService() {
        main.post { app.stopService(Intent(app, MotionRecordingService::class.java)) }
    }

    private fun bootCount(): Int = try {
        if (Build.VERSION.SDK_INT >= 24) {
            Settings.Global.getInt(app.contentResolver, Settings.Global.BOOT_COUNT, -1)
        } else -1
    } catch (_: Exception) { -1 }

    companion object {
        @Volatile private var instance: MotionRuntime? = null
        fun get(context: Context): MotionRuntime = instance ?: synchronized(this) {
            instance ?: MotionRuntime(context).also { instance = it }
        }
        fun hasMotionPermission(context: Context): Boolean = Build.VERSION.SDK_INT < 29 ||
            context.checkSelfPermission(Manifest.permission.ACTIVITY_RECOGNITION) == PackageManager.PERMISSION_GRANTED
        fun validLength(value: Double?): Boolean = value == null || (value.isFinite() && value > 0 && value <= 5.0)
    }
}
