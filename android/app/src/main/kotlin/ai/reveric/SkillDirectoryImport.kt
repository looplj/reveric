package ai.reveric

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodCall
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.util.Locale
import java.util.UUID

internal class SkillImportLimit : IOException("Skill import exceeds its size or file count limit.")

internal fun isPortableSkillSegment(name: String): Boolean =
    name.isNotEmpty() && !name.startsWith('.') && !name.endsWith('.') &&
        !name.endsWith(' ') && name.none { it.code < 32 || it in "\\:<>\"|?*/" } &&
        !reservedSkillName.containsMatchIn(name)

private val reservedSkillName = Regex(
    "^(con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])(?:\\.|$)",
    RegexOption.IGNORE_CASE,
)

internal data class SkillDirectoryPolicy(
    val ignored: Set<String>,
    val referenceExtensions: Set<String>,
    val scriptExtensions: Set<String>,
    val packageBytes: Long,
    val packageFiles: Int,
    val markdownBytes: Long,
    val scanEntries: Int,
    val candidates: Int,
    val scanMarkdownBytes: Long,
    val referenceBytes: Long,
    val totalReferenceBytes: Long,
    val referenceCount: Int,
) {
    companion object {
        fun from(call: MethodCall): SkillDirectoryPolicy {
            fun number(key: String) = requireNotNull(call.argument<Number>(key))
            return SkillDirectoryPolicy(
                ignored = requireNotNull(call.argument<List<String>>("ignored")).toSet(),
                referenceExtensions = requireNotNull(call.argument<List<String>>("referenceExtensions")).toSet(),
                scriptExtensions = requireNotNull(call.argument<List<String>>("scriptExtensions")).toSet(),
                packageBytes = number("packageBytes").toLong(),
                packageFiles = number("packageFiles").toInt(),
                markdownBytes = number("markdownBytes").toLong(),
                scanEntries = number("scanEntries").toInt(),
                candidates = number("candidates").toInt(),
                scanMarkdownBytes = number("scanMarkdownBytes").toLong(),
                referenceBytes = number("referenceBytes").toLong(),
                totalReferenceBytes = number("totalReferenceBytes").toLong(),
                referenceCount = number("referenceCount").toInt(),
            )
        }
    }
}

/** Holds the picker grant and known documents for one skill import flow. */
internal class SkillDirectoryImport(
    private val resolver: ContentResolver,
    private val tree: Uri,
    private val policy: SkillDirectoryPolicy,
    private val checkActive: () -> Unit,
) {
    val token = UUID.randomUUID().toString()
    private val skills = mutableMapOf<String, Pair<String, String>>()

    fun scan(): List<Map<String, Any>> {
        val results = mutableListOf<Map<String, Any>>()
        var visited = 0
        var previewBytes = 0L
        val directories = ArrayDeque<Pair<String, String>>()
        directories.addLast(DocumentsContract.getTreeDocumentId(tree) to "")
        val seen = mutableSetOf<String>()
        while (directories.isNotEmpty()) {
            checkActive()
            val (id, prefix) = directories.removeLast()
            if (!seen.add(id)) continue
            val children = mutableListOf<Entry>()
            forEachChild(id) {
                if (++visited > policy.scanEntries) throw SkillImportLimit()
                children.add(it)
            }
            val hasScripts = children.any {
                if (it.isDirectory) it.name.equals("scripts", ignoreCase = true)
                else extensionOf(it.name) in policy.scriptExtensions
            }
            for (entry in children) {
                val path = if (prefix.isEmpty()) entry.name else "$prefix/${entry.name}"
                if (entry.isDirectory) {
                    val name = entry.name.lowercase(Locale.ROOT)
                    if (name !in sections) {
                        directories.addLast(entry.id to path)
                    }
                } else if (entry.name.equals("SKILL.md", ignoreCase = true)) {
                    if (results.size >= policy.candidates) throw SkillImportLimit()
                    val output = ByteArrayOutputStream()
                    val size = try {
                        copy(entry.id, output, policy.markdownBytes)
                    } catch (error: SkillImportLimit) {
                        android.util.Log.w("RevericSkillImport", "Skipping oversized SKILL.md")
                        continue
                    }
                    previewBytes += size
                    if (previewBytes > policy.scanMarkdownBytes) throw SkillImportLimit()
                    val key = skills.size.toString()
                    skills[key] = id to entry.id
                    results.add(mapOf(
                        "id" to key,
                        "path" to path,
                        "markdown" to output.toString(Charsets.UTF_8.name()),
                        "hasScripts" to hasScripts,
                    ))
                }
            }
        }
        return results.sortedBy { it["path"] as String }
    }

    fun copyPackage(key: String, destination: File) {
        val (parentId, markdownId) = skills[key] ?: throw IOException("Skill candidate is unavailable.")
        val counts = PackageCounts()
        var foundMarkdown = false
        val directories = ArrayDeque<Pair<String, String>>()
        forEachChild(parentId) { entry ->
            if (++counts.scanned > policy.scanEntries) throw SkillImportLimit()
            if (entry.isDirectory) {
                directories.addLast(entry.id to entry.name)
            } else if (entry.name.equals("SKILL.md", ignoreCase = true)) {
                if (entry.id == markdownId) {
                    counts.write(entry.id, "SKILL.md", destination)
                    foundMarkdown = true
                }
            } else {
                counts.write(entry.id, entry.name, destination)
            }
        }
        if (!foundMarkdown) throw IOException("SKILL.md is no longer available.")

        val visited = mutableSetOf(parentId)
        while (directories.isNotEmpty()) {
            val (id, prefix) = directories.removeLast()
            if (!visited.add(id)) throw IOException("Invalid skill provider directory tree.")
            forEachChild(id) { entry ->
                if (++counts.scanned > policy.scanEntries) throw SkillImportLimit()
                val path = "$prefix/${entry.name}"
                if (entry.isDirectory) {
                    directories.addLast(entry.id to path)
                } else {
                    counts.write(entry.id, path, destination)
                }
            }
        }
    }

    private inner class PackageCounts {
        private val paths = mutableSetOf<String>()
        private var bytes = 0L
        private var referenceCount = 0
        private var referenceBytes = 0L
        var scanned = 0

        fun write(id: String, path: String, destination: File) {
            if (!paths.add(path.lowercase(Locale.ROOT))) {
                throw IOException("Conflicting paths in skill package.")
            }
            if (paths.size > policy.packageFiles) throw SkillImportLimit()
            var limit = policy.packageBytes - bytes
            val reference = path.startsWith("references/") && extensionOf(path) in policy.referenceExtensions
            if (path == "SKILL.md") limit = minOf(limit, policy.markdownBytes)
            if (reference) {
                if (++referenceCount > policy.referenceCount) throw SkillImportLimit()
                limit = minOf(limit, policy.referenceBytes, policy.totalReferenceBytes - referenceBytes)
            }
            val file = File(destination, path)
            if (!file.parentFile!!.isDirectory && !file.parentFile!!.mkdirs()) {
                throw IOException("Unable to create skill package directory.")
            }
            if (!file.createNewFile()) throw IOException("Conflicting paths in skill package.")
            val size = file.outputStream().use { copy(id, it, limit) }
            bytes += size
            if (reference) referenceBytes += size
        }
    }

    private fun copy(id: String, output: OutputStream, limit: Long): Long {
        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, id)
        val input = resolver.openInputStream(uri) ?: throw IOException("Unable to read selected skill file.")
        return input.use {
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            var bytes = 0L
            while (true) {
                checkActive()
                val count = it.read(buffer)
                if (count == -1) break
                bytes += count
                if (bytes > limit) throw SkillImportLimit()
                output.write(buffer, 0, count)
            }
            bytes
        }
    }

    private fun forEachChild(id: String, visit: (Entry) -> Unit) {
        checkActive()
        val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
        val columns = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        resolver.query(childUri, columns, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                checkActive()
                val childId = cursor.getString(0) ?: continue
                val name = cursor.getString(1) ?: continue
                if (!isPortableSkillSegment(name)) continue
                val directory = cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR
                if (directory && name.lowercase(Locale.ROOT) in policy.ignored) continue
                visit(Entry(childId, name, directory))
            }
        } ?: throw IOException("Unable to enumerate selected skill directory.")
    }

    private data class Entry(val id: String, val name: String, val isDirectory: Boolean)
    private val sections = setOf("scripts", "assets", "references")

    private fun extensionOf(path: String): String =
        path.substringAfterLast('/').substringAfterLast('.', "").lowercase(Locale.ROOT)
}
