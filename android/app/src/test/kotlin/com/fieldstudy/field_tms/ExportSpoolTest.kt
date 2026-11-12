package com.fieldstudy.field_tms

import java.io.File
import java.io.FilterOutputStream
import java.io.IOException
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

class ExportSpoolTest {
    private val root = Files.createTempDirectory("field_export_test_").toFile()
    private fun file(): File {
        val directory = File(root, "spool-${root.listFiles()?.size ?: 0}")
        check(directory.mkdirs())
        return File(directory, "study.xlsx")
    }
    @After fun cleanup() { root.deleteRecursively() }

    @Test fun boundedAppendWritesAllBytesAndCancelRemovesFile() {
        val file = file()
        val spool = ExportSpool("token", file, "text/csv")
        val chunk = ByteArray(65536) { (it % 251).toByte() }
        spool.append(chunk); spool.append(chunk); spool.append(byteArrayOf(1, 2, 3))
        assertEquals(131075L, spool.bytes)
        spool.close()
        assertEquals(131075L, file.length())
        file.inputStream().use { input ->
            val actual = ByteArray(chunk.size)
            assertEquals(chunk.size, input.read(actual)); assertArrayEquals(chunk, actual)
            assertEquals(chunk.size, input.read(actual)); assertArrayEquals(chunk, actual)
            assertEquals(1, input.read()); assertEquals(2, input.read()); assertEquals(3, input.read())
            assertEquals(-1, input.read())
        }
        spool.delete(); spool.delete()
        assertFalse(file.parentFile!!.exists())
    }

    @Test fun oversizedChunkAndFileCapDeleteTheIncompleteSpool() {
        for (oversizedChunk in listOf(true, false)) {
            val file = file()
            val spool = ExportSpool("token", file, "text/csv", maxBytes = 100)
            try {
                spool.append(ByteArray(if (oversizedChunk) 65537 else 101))
                fail("Expected the chunk or size limit")
            } catch (_: IllegalArgumentException) {}
            assertNull(spool.output)
            assertFalse(file.parentFile!!.exists())
        }
    }

    @Test fun reserveFailureClosesAndDeletesWithoutConsumingReserve() {
        val file = file()
        val spool = ExportSpool("token", file, "text/csv", availableBytes = { 64L * 1024 * 1024 + 4 })
        try { spool.append(ByteArray(5)); fail("Expected reserve failure") }
        catch (_: ExportSpaceException) {}
        assertEquals(0L, spool.bytes)
        assertNull(spool.output)
        assertFalse(file.parentFile!!.exists())
    }

    @Test fun actualWriteFailureClosesTheStreamAndDeletesPartialFile() {
        val file = file()
        var closed = false
        val spool = ExportSpool("token", file, "text/csv", outputFactory = { path ->
            object : FilterOutputStream(path.outputStream()) {
                override fun write(bytes: ByteArray, offset: Int, length: Int) {
                    out.write(bytes, offset, minOf(length, 3))
                    throw IOException("Simulated full disk")
                }
                override fun close() { closed = true; super.close() }
            }
        })
        try { spool.append(ByteArray(10)); fail("Expected write failure") }
        catch (_: IOException) {}
        assertTrue(closed)
        assertNull(spool.output)
        assertFalse(file.parentFile!!.exists())
    }

    @Test fun flushFailureDeletesThePrivateFile() {
        val file = file()
        val spool = ExportSpool("token", file, "text/csv", outputFactory = { path ->
            object : FilterOutputStream(path.outputStream()) {
                override fun close() { super.close(); throw IOException("Simulated flush failure") }
            }
        })
        spool.append(byteArrayOf(1))
        try { spool.close(); fail("Expected close failure") }
        catch (_: IOException) {}
        assertFalse(file.parentFile!!.exists())
    }
}
