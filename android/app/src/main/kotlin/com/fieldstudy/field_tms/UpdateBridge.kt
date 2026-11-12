package com.fieldstudy.field_tms

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors

/** No updater service or polling. Only a daily idle check and an explicit install. */
class UpdateBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "field_tms/updates")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val prefs = activity.getSharedPreferences("app_updates", 0)
    private val repository = "th00tames1/Planting-TMS"
    @Suppress("DEPRECATION")
    private fun installed() = activity.packageManager.getPackageInfo(activity.packageName, PackageManager.GET_SIGNATURES)
    @Suppress("DEPRECATION")
    private fun installedCode() = installed().let { if (Build.VERSION.SDK_INT >= 28) it.longVersionCode else it.versionCode.toLong() }
    init {
        channel.setMethodCallHandler { call, result ->
            if (call.argument<String>("repository") != repository) { result.error("source", "Unknown update source.", null); return@setMethodCallHandler }
            when (call.method) {
                "settings" -> result.success(snapshot())
                "automatic" -> {
                    prefs.edit().putBoolean("automatic", call.argument<Boolean>("enabled") == true).apply()
                    result.success(snapshot())
                }
                "check" -> {
                    val force = call.argument<Boolean>("force") == true
                    worker.execute {
                        try {
                            val now = System.currentTimeMillis()
                            val elapsed = now - prefs.getLong("checkedAt", 0)
                            var message: String? = null
                            if (force || prefs.getBoolean("automatic", false) && (elapsed < 0 || elapsed > 86400000)) {
                                val release = json("https://api.github.com/repos/$repository/releases/latest", 1048576, allowNotFound = true)
                                if (release == null) {
                                    prefs.edit().remove("release").putLong("checkedAt", now).apply()
                                    message = "No published Android release yet."
                                } else {
                                    require(!release.optBoolean("draft") && !release.optBoolean("prerelease"))
                                    val assets = release.getJSONArray("assets")
                                    val manifestAsset = (0 until assets.length()).map { assets.getJSONObject(it) }.firstOrNull { it.optString("name") == "update.json" }
                                        ?: throw IllegalStateException("This release has no update manifest.")
                                    val manifestUrl = manifestAsset.getString("browser_download_url")
                                    require(validAsset(manifestUrl))
                                    val manifest = json(manifestUrl, 16384) ?: throw IllegalStateException("No update manifest.")
                                    val code = manifest.getLong("versionCode")
                                    require(code > 0 && code <= 2100000000 && manifest.getString("packageId") == activity.packageName)
                                    val name = manifest.getString("apkFile")
                                    require(Regex("[A-Za-z0-9._-]+\\.apk").matches(name))
                                    val asset = (0 until assets.length()).map { assets.getJSONObject(it) }.firstOrNull { it.optString("name") == name }
                                        ?: throw IllegalStateException("The APK is missing from this release.")
                                    val url = asset.getString("browser_download_url")
                                    require(validAsset(url))
                                    require(Regex("[0-9a-f]{64}").matches(manifest.getString("sha256")))
                                    val size = manifest.getLong("byteCount")
                                    require(size in 1..209715200 && size == asset.getLong("size"))
                                    manifest.put("url", url)
                                    prefs.edit().putString("release", manifest.toString()).putLong("checkedAt", now).apply()
                                    message = if (code > installedCode()) "A new version is ready to download." else "You are using the latest version."
                                }
                            }
                            val state = snapshot().toMutableMap(); if (message != null) state["message"] = message
                            main.post { result.success(state) }
                        } catch (_: Exception) { main.post { result.error("check", "Could not check GitHub. Your study is unaffected.", null) } }
                    }
                }
                "install" -> {
                    worker.execute {
                        try {
                            val release = prefs.getString("release", null)?.let(::JSONObject) ?: throw IllegalStateException("Check for updates first.")
                            require(release.getLong("versionCode") > installedCode())
                            val file = download(release)
                            verifyApk(file, release.getLong("versionCode"))
                            main.post {
                                try {
                                    val state = snapshot().toMutableMap()
                                    if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
                                        activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
                                        state["message"] = "Allow updates from Planting TMS, return here, then tap Download and install again."
                                    } else {
                                        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", file)
                                        activity.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                                        state["message"] = "Approve the update in Android's installation screen."
                                    }
                                    result.success(state)
                                } catch (_: Exception) { result.error("install", "Could not open the Android installer.", null) }
                            }
                        } catch (_: Exception) { main.post { result.error("download", "The update could not be downloaded or verified. Nothing was installed.", null) } }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
    private fun snapshot(): Map<String, Any?> {
        val release = prefs.getString("release", null)?.let(::JSONObject)
        return mapOf("supported" to true, "automatic" to prefs.getBoolean("automatic", false), "versionCode" to installedCode(), "versionName" to installed().versionName,
            "available" to (release != null && release.getLong("versionCode") > installedCode()), "latestVersion" to release?.optString("versionName"))
    }
    private fun validAsset(url: String): Boolean {
        val uri = Uri.parse(url)
        return uri.scheme == "https" && uri.host == "github.com" && uri.path?.startsWith("/$repository/releases/download/") == true && uri.userInfo == null
    }
    private fun connect(raw: String): HttpURLConnection {
        var url = URL(raw)
        repeat(6) {
            require(url.protocol == "https" && (url.host == "api.github.com" || url.host == "github.com" || url.host == "release-assets.githubusercontent.com" || url.host == "objects.githubusercontent.com"))
            val connection = url.openConnection() as HttpURLConnection
            connection.instanceFollowRedirects = false; connection.connectTimeout = 10000; connection.readTimeout = 15000
            connection.setRequestProperty("User-Agent", "Planting-TMS")
            connection.setRequestProperty("Accept", "application/vnd.github+json")
            val code = connection.responseCode
            if (code in listOf(301, 302, 303, 307, 308)) {
                val location = connection.getHeaderField("Location"); connection.disconnect()
                require(location != null); url = URL(url, location)
            } else return connection
        }
        throw IllegalStateException("Too many redirects.")
    }
    private fun json(url: String, limit: Int, allowNotFound: Boolean = false): JSONObject? {
        val connection = connect(url)
        try {
            if (connection.responseCode == 404 && allowNotFound) return null
            require(connection.responseCode == 200)
            val bytes = connection.inputStream.use { it.readBytesBounded(limit) }
            return JSONObject(bytes.toString(Charsets.UTF_8))
        } finally { connection.disconnect() }
    }
    private fun java.io.InputStream.readBytesBounded(limit: Int): ByteArray {
        val output = java.io.ByteArrayOutputStream(); val buffer = ByteArray(8192)
        while (true) { val count = read(buffer); if (count < 0) break; require(output.size() + count <= limit); output.write(buffer, 0, count) }
        return output.toByteArray()
    }
    private fun download(release: JSONObject): File {
        val directory = File(activity.cacheDir, "updates").also { it.mkdirs() }
        val code = release.getLong("versionCode")
        val target = File(directory, "planting-$code.apk")
        val expected = release.getString("sha256")
        if (target.exists() && target.length() == release.getLong("byteCount") && digest(target) == expected) return target
        val partial = File(directory, "download.part")
        val url = release.getString("url"); require(validAsset(url))
        val connection = connect(url)
        try {
            require(connection.responseCode == 200)
            connection.inputStream.use { input -> partial.outputStream().use { output ->
                val buffer = ByteArray(65536); var size = 0L
                while (true) { val count = input.read(buffer); if (count < 0) break; size += count; require(size <= release.getLong("byteCount")); output.write(buffer, 0, count) }
                require(size == release.getLong("byteCount")); output.fd.sync()
            } }
            require(digest(partial) == expected)
            require(partial.renameTo(target))
            // Keep only this validated update in the scoped cache directory.
            directory.listFiles()?.filter { it != target && (it.name == "download.part" || Regex("planting-[0-9]+\\.apk").matches(it.name)) }?.forEach { it.delete() }
            return target
        } finally { connection.disconnect(); if (partial.exists()) partial.delete() }
    }
    private fun digest(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input -> val buffer = ByteArray(65536); while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) } }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
    @Suppress("DEPRECATION")
    private fun verifyApk(file: File, expectedCode: Long) {
        val archive = activity.packageManager.getPackageArchiveInfo(file.path, PackageManager.GET_SIGNATURES) ?: throw IllegalStateException("Invalid APK.")
        val code = if (Build.VERSION.SDK_INT >= 28) archive.longVersionCode else archive.versionCode.toLong()
        require(archive.packageName == activity.packageName && code == expectedCode)
        val existing = installed().signatures?.map { it.toCharsString() }?.toSet()
        val incoming = archive.signatures?.map { it.toCharsString() }?.toSet()
        require(!existing.isNullOrEmpty() && incoming == existing)
    }
    fun dispose() { channel.setMethodCallHandler(null); worker.shutdown() }
}
