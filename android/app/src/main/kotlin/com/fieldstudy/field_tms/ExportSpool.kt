package com.fieldstudy.field_tms

import java.io.BufferedOutputStream
import java.io.File
import java.io.OutputStream

/** Private, single-owner export file. No workbook-sized byte array is retained. */
internal class ExportSpool(
    val token: String,
    val file: File,
    val mime: String,
    private val availableBytes: () -> Long = { file.usableSpace },
    private val reserveBytes: Long = 64L * 1024 * 1024,
    private val maxBytes: Long = 512L * 1024 * 1024,
    outputFactory: (File) -> OutputStream = { BufferedOutputStream(it.outputStream(), CHUNK) },
) {
    var output: OutputStream? = outputFactory(file)
        private set
    var bytes = 0L
        private set

    fun append(data: ByteArray, offset: Int = 0, length: Int = data.size) {
        try {
            require(length in 0..CHUNK && offset >= 0 && offset + length <= data.size)
            require(bytes + length <= maxBytes)
            if (availableBytes() < reserveBytes + length) throw ExportSpaceException()
            val stream = output ?: throw IllegalStateException("Export file is closed")
            stream.write(data, offset, length)
            bytes += length
        } catch (failure: Exception) {
            delete()
            throw failure
        }
    }

    fun close() {
        val stream = output
        output = null
        try { stream?.close() }
        catch (failure: Exception) {
            file.parentFile?.deleteRecursively()
            throw failure
        }
    }

    fun delete() {
        try { close() } catch (_: Exception) {}
        file.parentFile?.deleteRecursively()
    }

    companion object { const val CHUNK = 64 * 1024 }
}

internal class ExportSpaceException : Exception()
