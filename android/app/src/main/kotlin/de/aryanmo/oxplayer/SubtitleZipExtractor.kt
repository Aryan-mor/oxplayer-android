package de.aryanmo.oxplayer

import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipInputStream

object SubtitleZipExtractor {

    data class ExtractedSubtitle(
        val file: File,
    )

    fun extractBest(zipFile: File, targetDir: File): ExtractedSubtitle? {
        targetDir.mkdirs()
        val candidates = mutableListOf<Pair<String, File>>()
        ZipInputStream(zipFile.inputStream().buffered()).use { input ->
            var entry = input.nextEntry
            while (entry != null) {
                if (!entry.isDirectory) {
                    val name = entry.name.substringAfterLast('/')
                    val ext = name.substringAfterLast('.', "").lowercase()
                    if (ext in supportedExtensions) {
                        val output = File(targetDir, name.ifEmpty { "subtitle.$ext" })
                        output.parentFile?.mkdirs()
                        FileOutputStream(output).use { stream ->
                            input.copyTo(stream)
                        }
                        candidates.add(ext to output)
                    }
                }
                input.closeEntry()
                entry = input.nextEntry
            }
        }

        val preferredOrder = listOf("srt", "vtt", "ass", "ssa")
        for (ext in preferredOrder) {
            val hit = candidates.firstOrNull { it.first == ext }
            if (hit != null) {
                return ExtractedSubtitle(hit.second)
            }
        }
        return null
    }

    private val supportedExtensions = setOf("srt", "vtt", "ass", "ssa")
}