package com.fieldstudy.field_tms

import android.Manifest
import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.*
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.io.RandomAccessFile
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

class DelayAudioBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "field_tms/delay_audio")
    private val events = EventChannel(messenger, "field_tms/delay_audio_events")
    private var waiting: Pair<String, MethodChannel.Result>? = null
    private var player: MediaPlayer? = null
    init {
        events.setStreamHandler(object: EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) { DelayAudioService.listener = { sink.success(it) } }
            override fun onCancel(arguments: Any?) { DelayAudioService.listener = null }
        })
        channel.setMethodCallHandler { call, result ->
            val file = call.argument<String>("file")
            when (call.method) {
                "setTarget" -> {
                    waiting?.let { it.second.success(mapOf("file" to it.first, "status" to "cancelled")) }
                    waiting = null
                    player?.release(); player = null
                    if (file != null && !validFile(file)) result.error("file", "Invalid audio note.", null)
                    else if (file == null) DelayAudioService.command(activity, null, result::success)
                    else if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                        waiting = Pair(file, result)
                        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST)
                    } else DelayAudioService.command(activity, file, result::success)
                }
                "deleteStudy" -> {
                    val id = call.argument<String>("studyId")
                    if (id == null || !Regex("study-[0-9]+-[0-9]+").matches(id)) result.error("study", "Invalid study.", null)
                    else if (DelayAudioService.recording) result.error("active", "Stop recording before Reset.", null)
                    else {
                        player?.release(); player = null
                        val failed = directory(activity).listFiles()?.filter { it.name.startsWith("note-$id-") && validFile(it.name) }?.any { !it.delete() } == true
                        if (failed) result.error("delete", "Some audio notes could not be deleted.", null) else result.success(null)
                    }
                }
                "play" -> {
                    if (file == null || !validFile(file) || DelayAudioService.recording) result.error("audio", "Stop recording before playing a note.", null)
                    else try {
                        player?.release()
                        player = MediaPlayer().apply {
                            setDataSource(File(directory(activity), file).path)
                            setOnCompletionListener { it.release(); if (player === it) player = null }
                            setOnErrorListener { p, _, _ -> p.release(); if (player === p) player = null; true }
                            setOnPreparedListener { it.start() }
                            prepareAsync()
                        }
                        result.success(null)
                    } catch (_: Exception) { player?.release(); player = null; result.error("audio", "This audio note is unavailable.", null) }
                }
                "stopPlayback" -> { player?.release(); player = null; result.success(null) }
                else -> result.notImplemented()
            }
        }
    }
    fun onPermissions(request: Int): Boolean {
        if (request != REQUEST) return false
        val pending = waiting ?: return true
        waiting = null
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) DelayAudioService.command(activity, pending.first, pending.second::success)
        else pending.second.success(mapOf("file" to pending.first, "status" to "denied"))
        return true
    }
    fun dispose() {
        waiting?.let { it.second.success(mapOf("file" to it.first, "status" to "cancelled")) }; waiting = null
        player?.release(); player = null
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null); DelayAudioService.listener = null
    }
    companion object {
        private const val REQUEST = 7331
        fun validFile(name: String) = Regex("note-study-[0-9]+-[0-9]+-[0-9]+\\.m4a").matches(name)
        fun directory(context: Context) = File(context.filesDir, "delay-notes").also { it.mkdirs() }
    }
}

/** One encoder on one worker; AAC is written to disk, never retained in Dart. */
class DelayAudioService : Service() {
    private lateinit var thread: HandlerThread
    private lateinit var worker: Handler
    private val main = Handler(Looper.getMainLooper())
    private var recorder: MediaRecorder? = null
    private var current: String? = null
    private var started: String? = null
    override fun onCreate() {
        super.onCreate(); instance = this
        thread = HandlerThread("DelayAudio").apply { start() }; worker = Handler(thread.looper)
        if (Build.VERSION.SDK_INT >= 26) getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel(CHANNEL, "Delay audio notes", NotificationManager.IMPORTANCE_LOW))
    }
    override fun onBind(intent: Intent?) = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getLongExtra("request", 0) ?: 0
        val file = intent?.getStringExtra("file")
        try {
            if (file != null) {
                val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
                val notification = builder.setContentTitle("Recording Delay note").setContentText("Recording ends with Delay or Stop.").setSmallIcon(android.R.drawable.ic_btn_speak_now).setContentIntent(open).setOngoing(true).build()
                if (Build.VERSION.SDK_INT >= 29) startForeground(7332, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE) else startForeground(7332, notification)
            }
            worker.post {
                var value: Map<String, Any?>
                if (file == current && recorder != null) value = mapOf("file" to file, "status" to "recording", "startedUtc" to started)
                else {
                    val ended = finish()
                    value = if (file == null) ended ?: mapOf("status" to "off")
                    else if (id != counter.get()) mapOf("file" to file, "status" to "cancelled")
                    else begin(file)
                }
                main.post {
                    replies.remove(id)?.invoke(value)
                    if (id == counter.get() && !recording) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelfResult(startId) }
                }
            }
        } catch (_: Exception) {
            replies.remove(id)?.invoke(mapOf("file" to file, "status" to "error"))
            if (!recording) stopSelfResult(startId)
        }
        return START_NOT_STICKY
    }
    @Suppress("DEPRECATION")
    private fun begin(file: String): Map<String, Any?> {
        val output = File(DelayAudioBridge.directory(this), file)
        if (output.exists()) return mapOf("file" to file, "status" to "interrupted")
        var candidate: MediaRecorder? = null
        return try {
            candidate = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(this) else MediaRecorder()
            candidate.setAudioSource(MediaRecorder.AudioSource.MIC)
            candidate.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            candidate.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            candidate.setAudioChannels(1); candidate.setAudioSamplingRate(16000); candidate.setAudioEncodingBitRate(32000)
            candidate.setOutputFile(output.path)
            candidate.setOnErrorListener { failed, _, _ -> worker.post {
                if (recorder !== failed) return@post
                val result = finish("error")
                main.post { if (result != null) listener?.invoke(result); if (!recording) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() } }
            } }
            candidate.prepare(); candidate.start()
            recorder = candidate; current = file; started = utc(); recording = true
            mapOf("file" to file, "status" to "recording", "startedUtc" to started)
        } catch (_: Exception) {
            candidate?.release(); output.delete(); recording = false
            mapOf("file" to file, "status" to "error")
        }
    }
    private fun finish(reason: String = "saved"): Map<String, Any?>? {
        val active = recorder ?: return null
        val file = current
        var status = reason
        try { active.stop() } catch (_: RuntimeException) { status = "too_short"; if (file != null) File(DelayAudioBridge.directory(this), file).delete() }
        finally { active.release(); recorder = null; current = null; recording = false }
        if (status != "too_short" && file != null) {
            try { RandomAccessFile(File(DelayAudioBridge.directory(this), file), "rw").use { it.fd.sync() } }
            catch (_: Exception) { status = "error" }
        }
        return mapOf("file" to file, "status" to status, "startedUtc" to started, "endedUtc" to utc())
    }
    override fun onDestroy() {
        instance = null
        worker.post { finish(); thread.quitSafely() }
        super.onDestroy()
    }
    companion object {
        private const val CHANNEL = "delay_audio"
        private val counter = AtomicLong()
        var listener: ((Map<String, Any?>) -> Unit)? = null
        private val replies = ConcurrentHashMap<Long, (Map<String, Any?>) -> Unit>()
        @Volatile private var instance: DelayAudioService? = null
        @Volatile var recording = false; private set
        private fun utc() = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date())
        fun command(context: Context, file: String?, reply: (Map<String, Any?>) -> Unit) {
            val id = counter.incrementAndGet()
            replies[id] = reply
            val intent = Intent(context, DelayAudioService::class.java).putExtra("request", id).putExtra("file", file)
            try { if (file != null && Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent) }
            catch (_: Exception) { replies.remove(id); reply(mapOf("file" to file, "status" to "error")) }
        }
    }
}
