package com.fieldstudy.field_tms

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Bounded chunks spool in app-private cache, then copy to a user-chosen URI. */
class ExportBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "field_tms/export")
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val disposed = AtomicBoolean(false)
    private val root = File(activity.cacheDir, "field_exports")
    // The following state is owned only by the IO executor.
    private var spool: ExportSpool? = null
    private var pending: MethodChannel.Result? = null
    private var pendingCode: Int? = null
    private var nextCode = REQUEST_FIRST

    init {
        // Stale private files from a killed process have no external references.
        io.execute { root.listFiles()?.forEach { it.deleteRecursively() }; root.mkdirs() }
        channel.setMethodCallHandler { call, result ->
            if (disposed.get()) { error(result, "export_unavailable"); return@setMethodCallHandler }
            io.execute { handle(call, result) }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (disposed.get()) { error(result, "export_unavailable"); return }
        val args = call.arguments as? Map<*, *>
        when (call.method) {
            "begin" -> {
                if (spool != null) { error(result, "export_busy"); return }
                try {
                    val created = create(args) ?: run { error(result, "export_invalid"); return }
                    spool = created
                    success(result, mapOf("token" to created.token))
                } catch (failure: Exception) { fail(result, failure) }
            }
            "append" -> {
                val current = matching(args, result) ?: return
                if (current.output == null) { error(result, "export_busy"); return }
                val bytes = args?.get("bytes") as? ByteArray
                if (bytes == null || bytes.size > CHUNK) {
                    fail(result, IllegalArgumentException("Invalid chunk")); return
                }
                try { append(current, bytes); success(result, null) }
                catch (failure: Exception) { fail(result, failure) }
            }
            "finish" -> {
                val current = matching(args, result) ?: return
                if (pending != null || current.output == null) { error(result, "export_busy"); return }
                try { current.close(); present(current, result) }
                catch (failure: Exception) { fail(result, failure) }
            }
            "abort" -> {
                val token = args?.get("token") as? String
                if (spool?.token == token) {
                    val waiting = pending; pending = null
                    val code = pendingCode; pendingCode = null
                    cleanup()
                    if (code != null) main.post { activity.finishActivity(code) }
                    if (waiting != null) success(waiting, mapOf("status" to "cancelled"))
                }
                success(result, null)
            }
            // Compatibility for direct callers. The app uses begin/append/finish.
            "save" -> {
                if (spool != null) { error(result, "export_busy"); return }
                val bytes = args?.get("bytes") as? ByteArray
                if (bytes == null || bytes.size > 32 * 1024 * 1024) { error(result, "export_invalid"); return }
                try {
                    val created = create(args) ?: run { error(result, "export_invalid"); return }
                    spool = created
                    var offset = 0
                    while (offset < bytes.size) {
                        val size = minOf(CHUNK, bytes.size - offset)
                        created.append(bytes, offset, size)
                        offset += size
                    }
                    created.close(); present(created, result)
                } catch (failure: Exception) { fail(result, failure) }
            }
            else -> main.post { result.notImplemented() }
        }
    }

    private fun create(args: Map<*, *>?): ExportSpool? {
        val name = args?.get("fileName") as? String ?: return null
        val mime = args["mimeType"] as? String ?: return null
        if (name.isBlank() || name.length > 128 || name == "." || name == ".." ||
            name.contains('/') || name.contains('\\') || mime !in MIMES) return null
        root.mkdirs()
        checkSpace(root, CHUNK)
        val token = UUID.randomUUID().toString()
        val directory = File(root, token)
        if (!directory.mkdirs()) throw IllegalStateException("Cannot create export directory")
        return try { ExportSpool(token, File(directory, name), mime) }
        catch (failure: Exception) { directory.deleteRecursively(); throw failure }
    }

    private fun matching(args: Map<*, *>?, result: MethodChannel.Result): ExportSpool? {
        val current = spool
        if (current == null || current.token != args?.get("token")) {
            error(result, "export_invalid"); return null
        }
        return current
    }

    private fun append(current: ExportSpool, bytes: ByteArray) = current.append(bytes)

    private fun checkSpace(file: File, additional: Int) {
        if (file.usableSpace < RESERVE_BYTES + additional) throw ExportSpaceException()
    }

    private fun present(current: ExportSpool, result: MethodChannel.Result) {
        pending = result
        val code = nextCode
        nextCode = if (nextCode == REQUEST_LAST) REQUEST_FIRST else nextCode + 1
        pendingCode = code
        main.post {
            if (disposed.get()) return@post
            try {
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = current.mime
                    putExtra(Intent.EXTRA_TITLE, current.file.name)
                }
                activity.startActivityForResult(intent, code)
            } catch (_: Exception) {
                io.execute { if (spool === current) { pending = null; pendingCode = null; cleanup(); error(result, "export_failed") } }
            }
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode !in REQUEST_FIRST..REQUEST_LAST) return false
        if (disposed.get()) return true
        io.execute {
            // A dismissed old picker cannot complete or delete a newer export.
            if (requestCode != pendingCode) return@execute
            val result = pending ?: return@execute
            val current = spool ?: return@execute
            pending = null
            pendingCode = null
            if (resultCode != Activity.RESULT_OK) {
                cleanup(); success(result, mapOf("status" to "cancelled")); return@execute
            }
            val uri = data?.data
            val saved = try {
                if (uri == null) throw IllegalStateException("No document URI")
                val output = activity.contentResolver.openOutputStream(uri, "w")
                    ?: throw IllegalStateException("No document stream")
                output.use { target ->
                    current.file.inputStream().use { input -> input.copyTo(target, CHUNK) }
                    target.flush()
                }
                true
            } catch (_: Exception) {
                if (uri != null) try { DocumentsContract.deleteDocument(activity.contentResolver, uri) } catch (_: Exception) {}
                false
            }
            cleanup()
            if (saved) success(result, mapOf("status" to "saved")) else error(result, "export_failed")
        }
        return true
    }

    private fun cleanup() { spool?.delete(); spool = null }
    private fun fail(result: MethodChannel.Result, failure: Exception) {
        cleanup()
        error(result, if (failure is ExportSpaceException) "export_space" else "export_failed")
    }
    private fun success(result: MethodChannel.Result, value: Any?) { main.post { result.success(value) } }
    private fun error(result: MethodChannel.Result, code: String) {
        main.post { result.error(code, if (code == "export_space") "Not enough free space to prepare this export." else "Could not save the file. Try again.", null) }
    }

    fun dispose() {
        if (!disposed.compareAndSet(false, true)) return
        channel.setMethodCallHandler(null)
        io.execute {
            pending?.let { error(it, "export_unavailable") }; pending = null; pendingCode = null
            cleanup()
        }
        io.shutdown()
    }

    companion object {
        private const val REQUEST_FIRST = 7316
        private const val REQUEST_LAST = 8315
        private const val CHUNK = 64 * 1024
        private const val RESERVE_BYTES = 64L * 1024 * 1024
        private val MIMES = setOf("text/csv", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    }
}
