package ai.reveric

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.StatFs
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "reveric/backup_import")
            .setMethodCallHandler { call, result ->
                if (call.method != "pickBackup") {
                    result.notImplemented()
                } else if (pendingBackupResult != null) {
                    result.error("backup_import_busy", "Backup selection or copy is running.", null)
                } else {
                    pendingBackupResult = result
                    try {
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            // Providers may report ZIP files as generic binary data.
                            // The restore service validates the archive contents after copying.
                            type = "*/*"
                            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(
                                "application/zip",
                                "application/x-zip-compressed",
                                "application/octet-stream",
                            ))
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }, BACKUP_IMPORT_REQUEST_CODE)
                    } catch (error: Exception) {
                        pendingBackupResult = null
                        result.error("backup_picker_failed", error.message, null)
                    }
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ai.reveric.director/storage").setMethodCallHandler { call, result ->
            if (call.method != "availableBytes") { result.notImplemented(); return@setMethodCallHandler }
            try {
                val path = call.argument<String>("path") ?: throw IllegalArgumentException("path")
                result.success(StatFs(path).availableBytes)
            } catch (error: Exception) {
                result.error("storage_probe_failed", "Unable to query private volume", null)
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("invalid_path", "APK path is required.", null)
                            return@setMethodCallHandler
                        }

                        try {
                            result.success(installApk(path))
                        } catch (error: IllegalArgumentException) {
                            result.error("invalid_apk", error.message, null)
                        } catch (error: ActivityNotFoundException) {
                            result.error("installer_missing", error.message, null)
                        } catch (error: Exception) {
                            result.error("install_failed", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_UI_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setFullscreen" -> {
                        val enabled = call.argument<Boolean>("enabled")
                        if (enabled == null) {
                            result.error(
                                "invalid_fullscreen_state",
                                "Fullscreen state is required.",
                                null,
                            )
                            return@setMethodCallHandler
                        }

                        setFullscreen(enabled)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DIRECTORY_IMPORT_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickAndCopyDirectory" -> pickAndCopyDirectory(call, result)
                "scanSkillDirectory" -> {
                    val policy = try {
                        SkillDirectoryPolicy.from(call)
                    } catch (error: IllegalArgumentException) {
                        result.error("directory_import_failed", "Invalid skill directory policy.", null)
                        return@setMethodCallHandler
                    }
                    pickAndCopyDirectory(call, result, policy)
                }
                "copySkillPackage" -> copySkillPackage(call, result)
                "closeSkillDirectory" -> {
                    if (skillImport?.token == call.argument<String>("token")) skillImport = null
                    result.success(null)
                }
                "exportSkillDirectory" -> pickAndExportSkillDirectory(call, result)
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        when (requestCode) {
            BACKUP_IMPORT_REQUEST_CODE -> handleBackupImportResult(resultCode, data)
            DIRECTORY_IMPORT_REQUEST_CODE -> handleDirectoryImportResult(resultCode, data)
            DIRECTORY_EXPORT_REQUEST_CODE -> handleDirectoryExportResult(resultCode, data)
            else -> super.onActivityResult(requestCode, resultCode, data)
        }
    }

    private fun handleBackupImportResult(resultCode: Int, data: Intent?) {
        val result = pendingBackupResult ?: return
        if (resultCode != RESULT_OK) {
            pendingBackupResult = null
            result.success(null)
            return
        }
        val uri = data?.data
        if (uri == null) {
            pendingBackupResult = null
            result.error("backup_import_failed", "Selected document URI is missing.", null)
            return
        }
        Thread {
            var target: File? = null
            try {
                // Never pass the ZIP bytes through the platform channel. A fixed name
                // also keeps provider-controlled display names out of filesystem paths.
                val file = File.createTempFile("reveric_restore_", ".zip", cacheDir)
                target = file
                val started = android.os.SystemClock.elapsedRealtime()
                val digest = java.security.MessageDigest.getInstance("SHA-256")
                var reportedBytes: Long? = null
                var metadataError: String? = null
                try {
                    contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst() && !cursor.isNull(0)) reportedBytes = cursor.getLong(0)
                    }
                } catch (error: Exception) {
                    // Provider size metadata is optional; retain its failure in diagnostics.
                    metadataError = error.javaClass.simpleName
                }
                val bytes = contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(file).use { output ->
                        val buffer = ByteArray(64 * 1024)
                        var total = 0L
                        while (true) {
                            if (activityDestroyed) {
                                throw java.io.InterruptedIOException("Backup import activity closed.")
                            }
                            val count = input.read(buffer)
                            if (count < 0) break
                            output.write(buffer, 0, count)
                            digest.update(buffer, 0, count)
                            total += count
                        }
                        total
                    }
                } ?: throw java.io.IOException("Unable to open selected backup.")
                val sourceSha256 = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
                val elapsedMs = android.os.SystemClock.elapsedRealtime() - started
                val cachedBytes = file.length()
                val availableBytes = StatFs(cacheDir.path).availableBytes
                Handler(Looper.getMainLooper()).post {
                    if (pendingBackupResult === result) {
                        pendingBackupResult = null
                        result.success(mapOf(
                            "path" to file.path, "bytes" to bytes,
                            "reportedBytes" to reportedBytes, "cachedBytes" to cachedBytes,
                            "sourceSha256" to sourceSha256, "elapsedMs" to elapsedMs,
                            "availableBytes" to availableBytes,
                            "metadataError" to metadataError,
                        ))
                    } else {
                        if (!file.delete()) android.util.Log.w("RevericBackup", "Cache cleanup failed")
                    }
                }
            } catch (error: Exception) {
                if (target?.delete() == false) android.util.Log.w("RevericBackup", "Partial cache cleanup failed")
                android.util.Log.e("RevericBackup", "Backup copy failed", error)
                Handler(Looper.getMainLooper()).post {
                    if (pendingBackupResult === result) {
                        pendingBackupResult = null
                        result.error("backup_import_failed", error.message, null)
                    }
                }
            }
        }.start()
    }

    override fun onDestroy() {
        activityDestroyed = true
        pendingBackupResult?.error("backup_import_closed", "Backup import activity closed.", null)
        pendingBackupResult = null
        pendingDirectoryImportResult?.error("directory_import_failed", "Directory picker closed.", null)
        pendingDirectoryImportResult = null
        pendingDirectoryExportResult?.error("directory_export_failed", "Directory picker closed.", null)
        pendingDirectoryExportResult = null
        pendingDirectoryExportSource?.let { source ->
            Thread { source.deleteRecursively() }.start()
        }
        pendingDirectoryExportSource = null
        skillImport = null
        super.onDestroy()
    }

    private fun handleDirectoryImportResult(resultCode: Int, data: Intent?) {
        val result = pendingDirectoryImportResult
        pendingDirectoryImportResult = null
        if (result == null) {
            return
        }
        val extensions = pendingDirectoryExtensions ?: DEFAULT_IMPORT_EXTENSIONS
        pendingDirectoryExtensions = null
        val skillPolicy = pendingSkillPolicy
        pendingSkillPolicy = null
        if (resultCode != RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }

        val treeUri = data.data!!
        if (skillPolicy == null) {
            copySelectedDirectory(treeUri, result, extensions)
        } else {
            scanSelectedSkills(treeUri, skillPolicy, result)
        }
    }

    private fun handleDirectoryExportResult(resultCode: Int, data: Intent?) {
        val result = pendingDirectoryExportResult
        pendingDirectoryExportResult = null
        val directory = pendingDirectoryExportSource
        pendingDirectoryExportSource = null
        if (result == null || directory == null) {
            return
        }
        if (resultCode != RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }
        writeSelectedSkills(data.data!!, directory, result)
    }

    private fun pickAndCopyDirectory(
        call: MethodCall,
        result: MethodChannel.Result,
        skillPolicy: SkillDirectoryPolicy? = null,
    ) {
        if (pendingDirectoryImportResult != null || pendingDirectoryExportResult != null || skillTransferRunning) {
            result.error("directory_import_busy", "A directory import is already running.", null)
            return
        }

        pendingDirectoryImportResult = result
        pendingSkillPolicy = skillPolicy
        pendingDirectoryExtensions = call.argument<List<String>>("extensions")
            ?.mapNotNull { extension ->
                extension.trim().lowercase().removePrefix(".").takeIf { it.isNotEmpty() }
            }
            ?.toSet()
            ?.takeIf { it.isNotEmpty() }
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            }
            startActivityForResult(intent, DIRECTORY_IMPORT_REQUEST_CODE)
        } catch (error: Exception) {
            pendingDirectoryImportResult = null
            pendingDirectoryExtensions = null
            pendingSkillPolicy = null
            result.error("directory_import_picker_failed", error.message, null)
        }
    }

    private fun copySelectedDirectory(
        uri: Uri,
        result: MethodChannel.Result,
        extensions: Set<String>,
    ) {
        Thread {
            var destination: File? = null
            try {
                val directoryName = queryDisplayName(uri)
                    ?: DocumentsContract.getTreeDocumentId(uri)
                        .substringAfter(':')
                        .substringAfterLast('/')
                        .ifEmpty { "Imported directory" }
                val importDestination = File(
                    cacheDir,
                    "reveric_directory_import_${UUID.randomUUID()}",
                )
                destination = importDestination
                if (!importDestination.mkdirs()) {
                    throw IllegalStateException("Unable to create import cache directory.")
                }
                val stats = CopyStats()
                copyDirectory(
                    uri,
                    DocumentsContract.getTreeDocumentId(uri),
                    importDestination,
                    extensions,
                    stats,
                )
                postDirectoryImportResult(
                    result,
                    mapOf(
                        "path" to importDestination.path,
                        "name" to directoryName,
                        "fileCount" to stats.fileCount,
                        "directoryCount" to stats.directoryCount,
                    ),
                )
            } catch (error: Exception) {
                destination?.deleteRecursively()
                postDirectoryImportError(result, error)
            }
        }.start()
    }

    private fun scanSelectedSkills(uri: Uri, policy: SkillDirectoryPolicy, result: MethodChannel.Result) {
        skillTransferRunning = true
        skillImport = null
        Thread {
            try {
                val session = SkillDirectoryImport(contentResolver, uri, policy, ::checkSkillTransferActive)
                val skills = session.scan()
                Handler(Looper.getMainLooper()).post {
                    skillTransferRunning = false
                    if (activityDestroyed) {
                        result.error("directory_import_failed", "Activity closed.", null)
                    } else {
                        skillImport = session
                        result.success(mapOf("token" to session.token, "skills" to skills))
                    }
                }
            } catch (error: Exception) {
                postSkillImportError(result, error)
            }
        }.start()
    }

    private fun copySkillPackage(call: MethodCall, result: MethodChannel.Result) {
        val session = skillImport
        val id = call.argument<String>("id")
        val destination = privateSkillCacheDirectory(call.argument<String>("path"), "reveric_skill_import_")
        if (session == null || session.token != call.argument<String>("token") ||
            id == null || destination == null || skillTransferRunning) {
            result.error("skill_package_unavailable", "Skill selection is unavailable.", null)
            return
        }
        skillTransferRunning = true
        Thread {
            try {
                session.copyPackage(id, destination)
                checkSkillTransferActive()
                Handler(Looper.getMainLooper()).post {
                    skillTransferRunning = false
                    if (activityDestroyed) {
                        destination.deleteRecursively()
                        result.error("skill_package_unavailable", "Activity closed.", null)
                    } else {
                        result.success(null)
                    }
                }
            } catch (error: Exception) {
                if (!destination.deleteRecursively()) {
                    android.util.Log.w("RevericSkillImport", "Unable to remove partial skill copy")
                }
                postSkillImportError(result, error)
            }
        }.start()
    }

    private fun postSkillImportError(result: MethodChannel.Result, error: Exception) {
        android.util.Log.w("RevericSkillImport", "Skill directory operation failed", error)
        Handler(Looper.getMainLooper()).post {
            skillTransferRunning = false
            val code = if (error is SkillImportLimit) "skill_package_too_large" else "skill_package_unavailable"
            result.error(code, error.message, null)
        }
    }

    private fun checkSkillTransferActive() {
        if (activityDestroyed) throw java.io.InterruptedIOException("Activity closed.")
    }

    private fun privateSkillCacheDirectory(path: String?, prefix: String): File? {
        if (path == null) return null
        return try {
            val directory = File(path).canonicalFile
            directory.takeIf {
                it.parentFile == cacheDir.canonicalFile && it.name.startsWith(prefix) && it.isDirectory
            }
        } catch (_: java.io.IOException) {
            null
        }
    }

    private fun pickAndExportSkillDirectory(call: MethodCall, result: MethodChannel.Result) {
        if (pendingDirectoryExportResult != null || pendingDirectoryImportResult != null || skillTransferRunning) {
            result.error("directory_export_busy", "A directory operation is already running.", null)
            return
        }
        val directory = privateSkillCacheDirectory(call.argument<String>("path"), "reveric_skill_export_")
        if (directory == null) {
            result.error("invalid_export_files", "Export source is unavailable.", null)
            return
        }
        pendingDirectoryExportResult = result
        pendingDirectoryExportSource = directory
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            }
            startActivityForResult(intent, DIRECTORY_EXPORT_REQUEST_CODE)
        } catch (error: Exception) {
            pendingDirectoryExportResult = null
            pendingDirectoryExportSource = null
            result.error("directory_export_picker_failed", error.message, null)
        }
    }

    private fun writeSelectedSkills(treeUri: Uri, source: File, result: MethodChannel.Result) {
        skillTransferRunning = true
        Thread {
            try {
                var written = 0
                fun visit(directory: File, target: Uri) {
                    val entries = directory.listFiles() ?: throw java.io.IOException("Unable to list staged skills.")
                    for (file in entries) {
                        checkSkillTransferActive()
                        val absolute = file.absoluteFile
                        if (!isPortableSkillSegment(file.name) || file.canonicalFile != absolute) {
                            throw java.io.IOException("Invalid staged skill path.")
                        }
                        if (file.isDirectory) {
                            visit(file, findOrCreateDirectory(treeUri, target, file.name))
                        } else if (file.isFile) {
                            writeSkillFile(treeUri, target, file)
                            written++
                        }
                    }
                }
                visit(source, treeUri)
                postDirectoryExportResult(
                    result,
                    mapOf(
                        "name" to (queryDisplayName(treeUri) ?: "Selected directory"),
                        "fileCount" to written,
                    ),
                )
            } catch (error: Exception) {
                postDirectoryExportError(result, error)
            } finally {
                if (activityDestroyed) source.deleteRecursively()
            }
        }.start()
    }

    private fun writeSkillFile(treeUri: Uri, parent: Uri, file: File) {
        val documentUri = findChildDocument(treeUri, parent, file.name, false)
            ?: DocumentsContract.createDocument(
                contentResolver,
                parent,
                "application/octet-stream",
                file.name,
            )
            ?: throw java.io.IOException("Unable to create export file.")
        contentResolver.openOutputStream(documentUri, "wt")?.use { output ->
            file.inputStream().use { input ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                while (true) {
                    checkSkillTransferActive()
                    val count = input.read(buffer)
                    if (count == -1) break
                    output.write(buffer, 0, count)
                }
            }
        } ?: throw java.io.IOException("Unable to write export file.")
    }

    private fun findOrCreateDirectory(
        treeUri: Uri,
        parentUri: Uri,
        name: String,
    ): Uri {
        return findChildDocument(treeUri, parentUri, name, true)
            ?: DocumentsContract.createDocument(
                contentResolver,
                parentUri,
                DocumentsContract.Document.MIME_TYPE_DIR,
                name,
            )
            ?: throw IllegalStateException("Unable to create export directory.")
    }

    private fun findChildDocument(
        treeUri: Uri,
        parentUri: Uri,
        name: String,
        directory: Boolean,
    ): Uri? {
        val parentDocumentId = if (parentUri == treeUri) {
            DocumentsContract.getTreeDocumentId(treeUri)
        } else {
            DocumentsContract.getDocumentId(parentUri)
        }
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            parentDocumentId,
        )
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
            while (cursor.moveToNext()) {
                if (cursor.getString(nameIndex) == name &&
                    (cursor.getString(mimeIndex) == DocumentsContract.Document.MIME_TYPE_DIR) == directory
                ) {
                    return DocumentsContract.buildDocumentUriUsingTree(
                        treeUri,
                        cursor.getString(idIndex),
                    )
                }
            }
        }
        return null
    }

    private fun copyDirectory(
        treeUri: Uri,
        documentId: String,
        destination: File,
        extensions: Set<String>,
        stats: CopyStats,
    ) {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, documentId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
            while (cursor.moveToNext()) {
                val name = sanitizeEntryName(cursor.getString(nameIndex)) ?: continue
                val childId = cursor.getString(idIndex) ?: continue
                val mimeType = cursor.getString(mimeIndex)
                val childUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, childId)
                if (mimeType == DocumentsContract.Document.MIME_TYPE_DIR) {
                    val childDestination = File(destination, name)
                    if (!childDestination.mkdirs() && !childDestination.isDirectory) {
                        throw IllegalStateException("Unable to create import subdirectory.")
                    }
                    copyDirectory(
                        treeUri,
                        childId,
                        childDestination,
                        extensions,
                        stats,
                    )
                    stats.directoryCount += 1
                } else if (isSupportedTextFile(name, extensions)) {
                    val target = File(destination, name)
                    contentResolver.openInputStream(childUri)?.use { input ->
                        FileOutputStream(target).use { output ->
                            stats.fileCount += 1
                            enforceImportLimits(stats)
                            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                            while (true) {
                                val count = input.read(buffer)
                                if (count == -1) break
                                stats.byteCount += count
                                enforceImportLimits(stats)
                                output.write(buffer, 0, count)
                            }
                        }
                    } ?: throw IllegalStateException("Unable to read selected document.")
                }
            }
        } ?: throw IllegalStateException("Unable to enumerate selected directory.")
    }

    private fun sanitizeEntryName(rawName: String?): String? {
        val name = rawName?.trim() ?: return null
        if (name.isEmpty() || name == "." || name == ".." || name.startsWith(".")) {
            return null
        }
        if (name.contains('/') || name.contains('\\') || name.any { it.code < 0x20 }) {
            return null
        }
        return name
    }

    private fun enforceImportLimits(stats: CopyStats) {
        if (stats.fileCount > MAX_IMPORT_FILES) {
            throw IllegalStateException("Selected directory contains too many files.")
        }
        if (stats.byteCount > MAX_IMPORT_BYTES) {
            throw IllegalStateException("Selected directory is too large to import.")
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        val documentUri = DocumentsContract.buildDocumentUriUsingTree(
            uri,
            DocumentsContract.getTreeDocumentId(uri),
        )
        contentResolver.query(
            documentUri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                return cursor.getString(0)?.takeIf { it.isNotBlank() }
            }
        }
        return null
    }

    private fun postDirectoryImportResult(result: MethodChannel.Result, value: Map<String, Any>) {
        Handler(Looper.getMainLooper()).post { result.success(value) }
    }

    private fun postDirectoryImportError(result: MethodChannel.Result, error: Exception) {
        Handler(Looper.getMainLooper()).post {
            result.error("directory_import_failed", error.message, null)
        }
    }

    private fun postDirectoryExportResult(result: MethodChannel.Result, value: Map<String, Any>) {
        Handler(Looper.getMainLooper()).post {
            skillTransferRunning = false
            result.success(value)
        }
    }

    private fun postDirectoryExportError(result: MethodChannel.Result, error: Exception) {
        Handler(Looper.getMainLooper()).post {
            skillTransferRunning = false
            result.error("directory_export_failed", error.message, null)
        }
    }

    private fun isSupportedTextFile(name: String, extensions: Set<String>): Boolean {
        val extension = name.substringAfterLast('.', "").lowercase()
        return extensions.contains(extension)
    }

    private data class CopyStats(
        var fileCount: Int = 0,
        var directoryCount: Int = 0,
        var byteCount: Long = 0,
    )


    private fun setFullscreen(enabled: Boolean) {
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        if (enabled) {
            controller.systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsetsCompat.Type.systemBars())
            return
        }
        controller.show(WindowInsetsCompat.Type.systemBars())
    }

    private fun installApk(path: String): Boolean {
        val apkFile = File(path)
        if (!apkFile.exists() || !apkFile.isFile) {
            throw IllegalArgumentException("APK file does not exist: $path")
        }

        val apkUri = FileProvider.getUriForFile(
            this,
            "$packageName.update_file_provider",
            apkFile,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(apkUri, APK_MIME_TYPE)
            clipData = ClipData.newUri(contentResolver, "Reveric update", apkUri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, true)
        }

        startActivity(intent)
        return true
    }

    companion object {
        private const val UPDATE_CHANNEL = "reveric/update"
        private const val SYSTEM_UI_CHANNEL = "reveric/system_ui"
        private const val DIRECTORY_IMPORT_CHANNEL = "reveric/android_directory_import"
        private const val DIRECTORY_IMPORT_REQUEST_CODE = 224
        private const val DIRECTORY_EXPORT_REQUEST_CODE = 225
        private const val BACKUP_IMPORT_REQUEST_CODE = 226
        private const val MAX_IMPORT_FILES = 4096
        private const val MAX_IMPORT_BYTES = 64L * 1024L * 1024L
        private val DEFAULT_IMPORT_EXTENSIONS = setOf("txt", "md", "csv")
        private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
    }

    private var pendingDirectoryImportResult: MethodChannel.Result? = null
    private var pendingBackupResult: MethodChannel.Result? = null
    @Volatile private var activityDestroyed = false
    private var pendingDirectoryExtensions: Set<String>? = null
    private var pendingSkillPolicy: SkillDirectoryPolicy? = null
    private var skillImport: SkillDirectoryImport? = null
    private var skillTransferRunning = false
    private var pendingDirectoryExportResult: MethodChannel.Result? = null
    private var pendingDirectoryExportSource: File? = null
}
