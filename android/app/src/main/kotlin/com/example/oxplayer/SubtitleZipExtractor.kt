package com.example.oxplayer

import androidx.media3.common.MimeTypes
import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipInputStream

/**
 * Extracts the first usable subtitle file from a SubDL ZIP.
 */
object SubtitleZipExtractor {

    data class ExtractedSubtitle(
        val file: File,
        val mimeType: String,
    )

    /**
     * Unzips [zipFile] into [targetDir] and returns the best subtitle match (.srt preferred).
     */
    fun extractBest(zipFile: File, targetDir: File): ExtractedSubtitle? {
        targetDir.mkdirs()
        val candidates = mutableListOf<Pair<String, File>>()
        ZipInputStream(zipFile.inputStream().buffered()).use { zis ->
            var entry = zis.nextEntry
            while (entry != null) {
                if (!entry.isDirectory) {
                    val name = entry.name.substringAfterLast('/')
                    val ext = name.substringAfterLast('.', "").lowercase()
                    if (ext in SUPPORTED) {
                        val out = File(targetDir, name.ifEmpty { "subtitle.$ext" })
                        out.parentFile?.mkdirs()
                        FileOutputStream(out).use { fos -> zis.copyTo(fos) }
                        candidates.add(ext to out)
                    }
                }
                zis.closeEntry()
                entry = zis.nextEntry
            }
        }
        val preferredOrder = listOf("srt", "vtt", "ass", "ssa")
        for (ext in preferredOrder) {
            val hit = candidates.firstOrNull { it.first == ext }
            if (hit != null) {
                return ExtractedSubtitle(hit.second, mimeForExt(ext))
            }
        }
        return null
    }

    private fun mimeForExt(ext: String): String = when (ext) {
        "srt" -> MimeTypes.APPLICATION_SUBRIP
        "vtt" -> MimeTypes.TEXT_VTT
        "ass", "ssa" -> MimeTypes.TEXT_SSA
        else -> MimeTypes.APPLICATION_SUBRIP
    }

    private val SUPPORTED = setOf("srt", "vtt", "ass", "ssa")
}
