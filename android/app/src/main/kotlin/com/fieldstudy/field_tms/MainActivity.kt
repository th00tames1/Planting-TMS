package com.fieldstudy.field_tms

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity(), EventChannel.StreamHandler {
    private val runtime by lazy { MotionRuntime.get(this) }
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var resumed = false
    private var pending: StartRequest? = null
    private var exportBridge: ExportBridge? = null
    private var locationBridge: LocationBridge? = null
    private var delayAudioBridge: DelayAudioBridge? = null
    private var updateBridge: UpdateBridge? = null
    private var capturePermissionsBridge: CapturePermissionsBridge? = null

    private class StartRequest(
        val sessionId: String,
        val length: Double?,
        val hasLength: Boolean,
        val result: MethodChannel.Result,
    ) {
        val cancelled = AtomicBoolean(false)
        var completed = false
        fun complete(snapshot: Map<String, Any?>) {
            if (completed) return
            completed = true
            result.success(snapshot)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Keep this app's window at a 60 Hz preference on high-refresh phones.
        window.attributes = window.attributes.apply { preferredRefreshRate = 60f }
        exportBridge = ExportBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        locationBridge = LocationBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        delayAudioBridge = DelayAudioBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        updateBridge = UpdateBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        capturePermissionsBridge = CapturePermissionsBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "field_tms/preferences").setMethodCallHandler { call, result ->
            val preferences = getSharedPreferences("appearance", MODE_PRIVATE)
            when (call.method) {
                "readDark" -> result.success(if (preferences.contains("dark")) preferences.getBoolean("dark", false) else null)
                "writeDark" -> { preferences.edit().putBoolean("dark", call.argument<Boolean>("dark") == true).apply(); result.success(null) }
                else -> result.notImplemented()
            }
        }
        methods = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "field_tms/motion").also {
            it.setMethodCallHandler(::handleMotion)
        }
        events = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "field_tms/motion_events").also {
            it.setStreamHandler(this)
        }
    }

    private fun handleMotion(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "read" -> runtime.read { result.success(it) }
            "start" -> {
                val args = call.arguments as? Map<*, *>
                val id = args?.get("sessionId") as? String
                val rawLength = args?.get("stepLengthM")
                val length = (rawLength as? Number)?.toDouble()
                val hasLength = args?.containsKey("stepLengthM") == true
                if (id.isNullOrBlank() || id.length > 128 ||
                    (rawLength != null && rawLength !is Number) || !MotionRuntime.validLength(length)) {
                    replyError(result, "Use a valid session ID and an optional step length up to 5 metres.")
                } else if (!resumed) {
                    replyError(result, "Open the app to start walking recording.")
                } else if (pending != null) {
                    replyError(result, "A walking permission request is already in progress.")
                } else {
                    val request = StartRequest(id, length, hasLength, result)
                    pending = request
                    runtime.preflight(id) { error ->
                        if (request.cancelled.get()) return@preflight
                        if (error != null) complete(request, error)
                        else runtime.read { snapshot ->
                            if (request.cancelled.get()) return@read
                            if (snapshot["source"] == "unavailable") {
                                runtime.start(id, length, hasLength, request.cancelled::get) {
                                    complete(request, it)
                                }
                            } else startIfPermitted(request)
                        }
                    }
                }
            }
            "pause" -> {
                val id = (call.arguments as? Map<*, *>)?.get("sessionId") as? String
                if (id.isNullOrBlank()) {
                    replyError(result, "A walking session ID is required.")
                } else {
                    val waiting = pending?.takeIf { it.sessionId == id }
                    if (waiting != null) {
                        waiting.cancelled.set(true)
                        MotionRecordingService.cancel(waiting.cancelled)
                        pending = null
                        runtime.cancelPending(id) {
                            waiting.complete(it)
                            result.success(it)
                        }
                    } else runtime.pause(id) { result.success(it) }
                }
            }
            "setStepLength" -> {
                val args = call.arguments as? Map<*, *>
                val raw = args?.get("stepLengthM")
                val value = (raw as? Number)?.toDouble()
                if ((raw != null && raw !is Number) || !MotionRuntime.validLength(value)) {
                    replyError(result, "Step length must be greater than zero and at most 5 metres.")
                } else runtime.setStepLength(value) { result.success(it) }
            }
            else -> result.notImplemented()
        }
    }

    private fun startIfPermitted(request: StartRequest) {
        if (MotionRuntime.hasMotionPermission(this)) startService(request)
        else runtime.permissionDenied(request.sessionId, request.length, request.hasLength) { complete(request, it) }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        capturePermissionsBridge?.onPermissions(requestCode)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (exportBridge?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun startService(request: StartRequest) {
        if (request.cancelled.get()) return
        MotionRecordingService.start(
            this, request.sessionId, request.length, request.hasLength, request.cancelled,
        ) { complete(request, it) }
    }

    private fun complete(request: StartRequest, value: Map<String, Any?>) {
        if (pending === request) pending = null
        request.complete(value)
    }

    private fun replyError(result: MethodChannel.Result, message: String) {
        runtime.read { result.success(it + mapOf("status" to "error", "distanceM" to null, "message" to message)) }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSink = events
        runtime.subscribe(this) { if (eventSink === events) events.success(it) }
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        runtime.unsubscribe(this) // The foreground service deliberately continues.
    }

    override fun onResume() { super.onResume(); resumed = true }
    override fun onPause() { resumed = false; super.onPause() }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        capturePermissionsBridge?.dispose(); capturePermissionsBridge = null
        updateBridge?.dispose(); updateBridge = null
        delayAudioBridge?.dispose()
        delayAudioBridge = null
        locationBridge?.dispose()
        locationBridge = null
        exportBridge?.dispose()
        exportBridge = null
        pending?.let { request ->
            request.cancelled.set(true)
            MotionRecordingService.cancel(request.cancelled)
            pending = null
            runtime.cancelPending(request.sessionId) { request.complete(it) }
        }
        eventSink = null
        runtime.unsubscribe(this)
        methods?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        super.cleanUpFlutterEngine(flutterEngine)
    }

}
