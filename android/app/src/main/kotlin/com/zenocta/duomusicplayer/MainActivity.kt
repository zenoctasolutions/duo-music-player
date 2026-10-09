package com.zenocta.duomusicplayer

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.RingtoneManager
import android.media.audiofx.Equalizer
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.annotation.NonNull
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap

class MainActivity : FlutterActivity() {

    private val RING_CHANNEL = "music_app/ringtone"
    private val EQ_CHANNEL = "music_app/equalizer"
    private val DOWNLOADS_CHANNEL = "music_app/downloads"
    private val MEDIA_CHANNEL = "music_app/mediastore"
    private val DUO_CHANNEL = "music_app/duo"
    private val SYSTEM_CHANNEL = "music_app/system"
    private val TAGS_CHANNEL = "music_app/tags"
    private val TAG = "MainActivity"

    companion object {
        // Ensure we attach the MethodChannels only once per process
        private var channelInitialized = false

        // Widget button tapped while the process was dead (see
        // WidgetActionActivity); Dart takes it once via takeWidgetAction.
        @Volatile private var pendingWidgetAction: String? = null
    }

    // Map sessionId -> Equalizer instance
    private val eqInstances = ConcurrentHashMap<Int, EqEngine>()

    // Sound effects on the same audio session (bass boost, virtualizer,
    // loudness). Created lazily; see applySoundEffects.
    private val bassInstances = ConcurrentHashMap<Int, android.media.audiofx.BassBoost>()
    private val virtInstances = ConcurrentHashMap<Int, android.media.audiofx.Virtualizer>()
    private val loudInstances = ConcurrentHashMap<Int, android.media.audiofx.LoudnessEnhancer>()

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        if (savedInstanceState == null) {
            intent?.getStringExtra(WidgetActionActivity.EXTRA_ACTION)?.let { pendingWidgetAction = it }
        }
        super.onCreate(savedInstanceState)
        TagWriteHelper.attach(this)
    }

    override fun onResume() {
        super.onResume()
        // Channels are registered once per process, so helpers that need
        // an Activity (system dialogs) always use the current one.
        TagWriteHelper.attach(this)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (TagWriteHelper.onActivityResult(applicationContext, requestCode, resultCode, data)) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        val engine = AudioServicePlugin.getFlutterEngine(context)

        if (!channelInitialized && engine != null) {
            channelInitialized = true
            Log.d(TAG, "Initializing MethodChannels on shared FlutterEngine")

            // CAST CHANNEL — Chromecast discovery / playback (CastHelper.kt)
            CastHelper.register(context.applicationContext, MethodChannel(engine.dartExecutor.binaryMessenger, "music_app/cast"))

            // TAGS CHANNEL — tag editor write access / file replace / image picker
            MethodChannel(engine.dartExecutor.binaryMessenger, TAGS_CHANNEL)
                .setMethodCallHandler { call, result -> TagWriteHelper.handle(context.applicationContext, call, result) }

            // SYSTEM CHANNEL — Material You wallpaper accent (Android 12+)
            MethodChannel(engine.dartExecutor.binaryMessenger, SYSTEM_CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "getSystemAccent" -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                try {
                                    // system_accent1_500 = the wallpaper-derived primary tone.
                                    result.success(context.getColor(android.R.color.system_accent1_500))
                                } catch (e: Exception) {
                                    result.success(null)
                                }
                            } else {
                                result.success(null)
                            }
                        }
                        "takeWidgetAction" -> {
                            result.success(pendingWidgetAction)
                            pendingWidgetAction = null
                        }
                        else -> result.notImplemented()
                    }
                }

            // DUO MODE CHANNEL — two songs at once, one per ear (DuoEngine.kt)
            val appCtx = context.applicationContext
            MethodChannel(engine.dartExecutor.binaryMessenger, DUO_CHANNEL)
                .setMethodCallHandler { call, result -> DuoEngine.handle(appCtx, call, result) }

            // RINGTONE CHANNEL (unchanged behavior)
            MethodChannel(engine.dartExecutor.binaryMessenger, RING_CHANNEL)
                .setMethodCallHandler { call, result ->
                    Log.d(TAG, "Method call on $RING_CHANNEL: ${call.method}")
                    when (call.method) {
                        "setRingtone" -> {
                            val path = call.argument<String>("path")
                            val titleArg = call.argument<String>("title")

                            if (path.isNullOrBlank()) {
                                result.error("invalid_args", "Missing 'path' argument", null)
                                return@setMethodCallHandler
                            }

                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                if (!Settings.System.canWrite(this)) {
                                    result.error("permission_required", "WRITE_SETTINGS permission required", null)
                                    return@setMethodCallHandler
                                }
                            }

                            Thread {
                                try {
                                    val srcFile = File(path)
                                    if (!srcFile.exists()) {
                                        runOnUiThread { result.error("file_not_found", "File not found at $path", null) }
                                        return@Thread
                                    }

                                    val title = titleArg ?: srcFile.nameWithoutExtension
                                    val uri = insertFileAsRingtone(srcFile, title)

                                    if (uri != null) {
                                        RingtoneManager.setActualDefaultRingtoneUri(this, RingtoneManager.TYPE_RINGTONE, uri)
                                        runOnUiThread { result.success(true) }
                                    } else {
                                        runOnUiThread { result.error("insert_failed", "Failed to insert content into MediaStore", null) }
                                    }
                                } catch (e: Exception) {
                                    e.printStackTrace()
                                    runOnUiThread { result.error("error", e.message ?: "Unknown error", null) }
                                }
                            }.start()
                        }

                        "openWriteSettings" -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                try {
                                    val intent = Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS).apply {
                                        data = Uri.parse("package:$packageName")
                                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    }
                                    startActivity(intent)
                                    result.success(true)
                                } catch (e: Exception) {
                                    result.error("intent_failed", "Could not open settings", e.message)
                                }
                            } else {
                                result.success(true)
                            }
                        }

                        "getRingtones" -> {
                            try {
                                val mgr = RingtoneManager(this)
                                mgr.setType(RingtoneManager.TYPE_RINGTONE)
                                val cursor = mgr.cursor
                                val list = ArrayList<Map<String, Any?>>()

                                val defaultUri: Uri? = RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_RINGTONE)

                                if (cursor != null && cursor.moveToFirst()) {
                                    do {
                                        val idIndex = cursor.getColumnIndex(MediaStore.Audio.Media._ID)
                                        val titleIndex = cursor.getColumnIndex(MediaStore.Audio.Media.TITLE)
                                        val dataIndex = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)

                                        val id = if (idIndex >= 0) cursor.getLong(idIndex) else -1L
                                        val title = if (titleIndex >= 0) cursor.getString(titleIndex) ?: "" else ""
                                        val data = if (dataIndex >= 0) cursor.getString(dataIndex) ?: "" else ""

                                        val contentUri = if (id >= 0) {
                                            ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
                                        } else {
                                            null
                                        }

                                        val map = HashMap<String, Any?>()
                                        map["id"] = id
                                        map["title"] = title
                                        map["data"] = data
                                        map["uri"] = contentUri?.toString() ?: ""
                                        map["isDefault"] = (contentUri != null && defaultUri != null && contentUri == defaultUri)

                                        list.add(map)
                                    } while (cursor.moveToNext())
                                }
                                cursor?.close()
                                result.success(list)
                            } catch (e: Exception) {
                                e.printStackTrace()
                                result.error("error", e.message ?: "Failed to read ringtones", null)
                            }
                        }

                        "setDefaultRingtoneUri" -> {
                            val uriStr = call.argument<String>("uri")
                            if (uriStr.isNullOrBlank()) {
                                result.error("invalid_args", "Missing 'uri' argument", null)
                                return@setMethodCallHandler
                            }

                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                if (!Settings.System.canWrite(this)) {
                                    result.error("permission_required", "WRITE_SETTINGS permission required", null)
                                    return@setMethodCallHandler
                                }
                            }

                            try {
                                val uri = Uri.parse(uriStr)
                                RingtoneManager.setActualDefaultRingtoneUri(this, RingtoneManager.TYPE_RINGTONE, uri)
                                result.success(true)
                            } catch (e: Exception) {
                                e.printStackTrace()
                                result.error("error", e.message ?: "Failed to set default ringtone by URI", null)
                            }
                        }

                        else -> {
                            Log.w(TAG, "Not implemented on RING_CHANNEL: ${call.method}")
                            result.notImplemented()
                        }
                    }
                }

            // EQUALIZER CHANNEL — backed by EqEngine (10-band on Android 9+,
            // device Equalizer otherwise) plus output-route reporting for
            // per-output EQ profiles.
            val eqChannel = MethodChannel(engine.dartExecutor.binaryMessenger, EQ_CHANNEL)
            registerOutputRouteCallback(context.applicationContext, eqChannel)
            eqChannel.setMethodCallHandler { call, result ->
                    val sid = (call.argument<Int>("sessionId") ?: 0)
                    try {
                        when (call.method) {
                            "initEqualizer" -> result.success(initEqualizerForSession(sid))
                            "getOutputRoute" -> result.success(currentOutputRoute(context.applicationContext))
                            "setSoundEffects" -> {
                                val bass = (call.argument<Int>("bass") ?: 0)
                                val virt = (call.argument<Int>("virtualizer") ?: 0)
                                val loud = (call.argument<Int>("loudnessMb") ?: 0)
                                result.success(applySoundEffects(sid, bass, virt, loud))
                            }
                            "releaseEqualizer" -> {
                                eqInstances.remove(sid)?.let {
                                    try { it.release() } catch (e: Exception) { Log.w(TAG, "release error: ${e.message}") }
                                }
                                result.success(true)
                            }
                            else -> {
                                val eq = eqInstances[sid]
                                if (eq == null) {
                                    result.error("no_eq", "Equalizer not initialized for session $sid", null)
                                    return@setMethodCallHandler
                                }
                                when (call.method) {
                                    "setEnabled" -> { eq.enabled = call.argument<Boolean>("enabled") ?: false; result.success(true) }
                                    "getBandLevelRange" -> result.success(eq.bandLevelRange.toList())
                                    "getCenterBandFreqs" -> result.success(eq.centerFreqsHz)
                                    "getPresetNames" -> result.success(eq.presetNames)
                                    "usePreset" -> {
                                        try {
                                            eq.usePreset(call.argument<Int>("index") ?: 0)
                                            result.success(true)
                                        } catch (e: Exception) {
                                            result.error("preset_failed", "Failed to use preset: ${e.message}", null)
                                        }
                                    }
                                    "getBandLevel" -> result.success(eq.getBandLevel(call.argument<Int>("band") ?: 0))
                                    "setBandLevel" -> {
                                        try {
                                            eq.setBandLevel(call.argument<Int>("band") ?: 0, call.argument<Int>("level") ?: 0)
                                            result.success(true)
                                        } catch (e: Exception) {
                                            result.error("set_failed", e.message, null)
                                        }
                                    }
                                    else -> {
                                        Log.w(TAG, "Not implemented on EQ_CHANNEL: ${call.method}")
                                        result.notImplemented()
                                    }
                                }
                            }
                        }
                    } catch (e: Exception) {
                        e.printStackTrace()
                        result.error("error", e.message ?: "Unknown error in equalizer handler", null)
                    }
                }

            MethodChannel(engine.dartExecutor.binaryMessenger, DOWNLOADS_CHANNEL)
                .setMethodCallHandler { call, result ->
                    Log.d(TAG, "Method call on $DOWNLOADS_CHANNEL: ${call.method}")
                    when (call.method) {
                        "getSdkInt" -> {
                            result.success(Build.VERSION.SDK_INT)
                        }

                        "lookupDownload" -> {
                            val displayName = call.argument<String>("displayName")
                            if (displayName.isNullOrBlank()) {
                                result.error("invalid_args", "Missing 'displayName' argument", null)
                                return@setMethodCallHandler
                            }
                            Thread {
                                val found = findExistingDownload(displayName)
                                runOnUiThread { result.success(found) }
                            }.start()
                        }

                        "publishToDownloads" -> {
                            val sourcePath = call.argument<String>("sourcePath")
                            val displayName = call.argument<String>("displayName")
                            val mimeType = call.argument<String>("mimeType") ?: "audio/mpeg"

                            if (sourcePath.isNullOrBlank() || displayName.isNullOrBlank()) {
                                result.error("invalid_args", "Missing 'sourcePath' or 'displayName' argument", null)
                                return@setMethodCallHandler
                            }

                            Thread {
                                try {
                                    val published = publishToDownloads(sourcePath, displayName, mimeType)
                                    runOnUiThread { result.success(published) }
                                } catch (e: PublishException) {
                                    Log.e(TAG, "publishToDownloads failed: ${e.message}")
                                    runOnUiThread { result.error(e.code, e.message, null) }
                                } catch (e: Exception) {
                                    Log.e(TAG, "publishToDownloads failed: ${e.message}")
                                    val msg = e.message?.lowercase() ?: ""
                                    val code = when {
                                        msg.contains("enospc") || msg.contains("no space") -> "storage_error"
                                        msg.contains("eacces") || msg.contains("permission") -> "permission_error"
                                        else -> "error"
                                    }
                                    runOnUiThread { result.error(code, e.message ?: "Failed to publish to Downloads", null) }
                                }
                            }.start()
                        }

                        else -> {
                            Log.w(TAG, "Not implemented on $DOWNLOADS_CHANNEL: ${call.method}")
                            result.notImplemented()
                        }
                    }
                }

            // MEDIASTORE CHANNEL — lets the Dart side ask the OS's already-
            // indexed media database for every audio file instead of doing
            // its own recursive java.io directory walk across a dozen+
            // storage roots on every app open. MediaStore.Audio.Media is
            // updated by the system media scanner as files are added/
            // removed, so this query is a fast indexed lookup (typically
            // tens of milliseconds) rather than a filesystem crawl, and
            // naturally reflects new files without any extra bookkeeping.
            MethodChannel(engine.dartExecutor.binaryMessenger, MEDIA_CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "getAudioInfo" -> {
                            val path = call.argument<String>("path")
                            if (path == null) {
                                result.error("NO_PATH", "path required", null)
                            } else {
                                Thread {
                                    val info = readAudioInfo(path)
                                    runOnUiThread { result.success(info) }
                                }.start()
                            }
                        }
                        "queryAudioFiles" -> {
                            Thread {
                                val files = queryAudioFiles()
                                runOnUiThread { result.success(files) }
                            }.start()
                        }
                        else -> {
                            Log.w(TAG, "Not implemented on $MEDIA_CHANNEL: ${call.method}")
                            result.notImplemented()
                        }
                    }
                }
        } else {
            Log.d(TAG, "MethodChannels already initialized or engine is null")
        }

        return engine
    }

    /** Thrown by [publishToDownloads] with a Flutter-facing error code already attached. */
    private class PublishException(val code: String, override val message: String) : Exception(message)

    private fun downloadsRelativePath(): String = Environment.DIRECTORY_DOWNLOADS + "/"

    /**
     * Looks up a file previously published to the public Downloads folder by
     * [displayName]. Returns null if nothing valid is there yet — used both
     * to skip re-conversion/re-cutting entirely when a valid output already
     * exists, and internally by [publishToDownloads] to avoid duplicate
     * copies of the same output file.
     */
    private fun findExistingDownload(displayName: String): Map<String, Any?>? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
                val projection = arrayOf(
                    MediaStore.MediaColumns._ID,
                    MediaStore.MediaColumns.SIZE,
                    MediaStore.MediaColumns.DATA
                )
                val selection = "${MediaStore.MediaColumns.DISPLAY_NAME}=? AND ${MediaStore.MediaColumns.RELATIVE_PATH}=?"
                val args = arrayOf(displayName, downloadsRelativePath())
                contentResolver.query(collection, projection, selection, args, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val idIdx = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                        val sizeIdx = cursor.getColumnIndex(MediaStore.MediaColumns.SIZE)
                        val dataIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
                        val id = cursor.getLong(idIdx)
                        val size = if (sizeIdx >= 0) cursor.getLong(sizeIdx) else 0L
                        val dataPath = if (dataIdx >= 0) cursor.getString(dataIdx) else null
                        val uri = ContentUris.withAppendedId(collection, id)
                        return mapOf("uri" to uri.toString(), "path" to dataPath, "size" to size)
                    }
                }
                null
            } else {
                val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                val f = File(dir, displayName)
                if (f.exists() && f.length() > 0) {
                    mapOf("uri" to Uri.fromFile(f).toString(), "path" to f.absolutePath, "size" to f.length())
                } else {
                    null
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "findExistingDownload error: ${e.message}")
            null
        }
    }

    /**
     * Copies [sourcePath] (a temp file produced by ffmpeg) into the public
     * Downloads folder as [displayName], reusing an existing valid file with
     * the same name instead of copying again — prevents duplicate output
     * files across repeated conversions/cuts of the same song.
     */
    private fun publishToDownloads(sourcePath: String, displayName: String, mimeType: String): Map<String, Any?> {
        val srcFile = File(sourcePath)
        if (!srcFile.exists() || srcFile.length() <= 0L) {
            throw PublishException("invalid_source", "Source file is missing or empty: $sourcePath")
        }

        val existing = findExistingDownload(displayName)
        if (existing != null && ((existing["size"] as? Long ?: 0L) > 0L)) {
            val existingPath = existing["path"] as? String
            if (existingPath == null || File(existingPath).exists()) {
                return existing + mapOf("reused" to true)
            }
        }

        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                    put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, downloadsRelativePath())
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
                val uri = contentResolver.insert(collection, values)
                    ?: throw PublishException("error", "MediaStore insert into Downloads failed")

                try {
                    val out = contentResolver.openOutputStream(uri)
                        ?: throw PublishException("io_error", "Could not open output stream for Downloads")
                    out.use { os -> FileInputStream(srcFile).use { fis -> fis.copyTo(os) } }
                    val doneValues = ContentValues()
                    doneValues.put(MediaStore.MediaColumns.IS_PENDING, 0)
                    contentResolver.update(uri, doneValues, null, null)
                } catch (e: Exception) {
                    contentResolver.delete(uri, null, null)
                    throw e
                }

                var path: String? = null
                contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        val idx = c.getColumnIndex(MediaStore.MediaColumns.DATA)
                        if (idx >= 0) path = c.getString(idx)
                    }
                }
                mapOf("uri" to uri.toString(), "path" to path, "size" to srcFile.length(), "reused" to false)
            } else {
                val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                if (!dir.exists()) dir.mkdirs()
                val outFile = File(dir, displayName)
                srcFile.copyTo(outFile, overwrite = true)

                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DATA, outFile.absolutePath)
                    put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                    put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                }
                val uri = contentResolver.insert(MediaStore.Files.getContentUri("external"), values)
                mapOf(
                    "uri" to (uri?.toString() ?: Uri.fromFile(outFile).toString()),
                    "path" to outFile.absolutePath,
                    "size" to outFile.length(),
                    "reused" to false
                )
            }
        } catch (e: PublishException) {
            throw e
        } catch (e: IOException) {
            val msg = e.message?.lowercase() ?: ""
            val code = if (msg.contains("enospc") || msg.contains("no space")) "storage_error" else "io_error"
            throw PublishException(code, e.message ?: "I/O error while saving to Downloads")
        } catch (e: SecurityException) {
            throw PublishException("permission_error", e.message ?: "Permission denied while saving to Downloads")
        }
    }

    /**
     * Queries every audio file MediaStore already knows about (its DATA
     * column gives an absolute filesystem path, same as
     * [findExistingDownload] already relies on for Downloads). Filtered to
     * non-empty files only — everything else (extension filtering, dedup,
     * existence re-check) is left to the Dart side, same as the old
     * directory-walk path did.
     */
    /** Format, bitrate, sample rate and channel count of one audio file (for the "audio quality" badge). */
    private fun readAudioInfo(path: String): Map<String, Any?> {
        val out = HashMap<String, Any?>()
        out["size"] = try { File(path).length() } catch (e: Exception) { 0L }
        val extractor = android.media.MediaExtractor()
        try {
            extractor.setDataSource(path)
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(android.media.MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("audio/")) continue
                out["mime"] = mime
                if (format.containsKey(android.media.MediaFormat.KEY_SAMPLE_RATE)) out["sampleRate"] = format.getInteger(android.media.MediaFormat.KEY_SAMPLE_RATE)
                if (format.containsKey(android.media.MediaFormat.KEY_CHANNEL_COUNT)) out["channels"] = format.getInteger(android.media.MediaFormat.KEY_CHANNEL_COUNT)
                if (format.containsKey(android.media.MediaFormat.KEY_BIT_RATE)) out["bitrate"] = format.getInteger(android.media.MediaFormat.KEY_BIT_RATE)
                if (format.containsKey("bits-per-sample")) out["bitsPerSample"] = format.getInteger("bits-per-sample")
                if (format.containsKey(android.media.MediaFormat.KEY_DURATION)) out["durationMs"] = format.getLong(android.media.MediaFormat.KEY_DURATION) / 1000
                break
            }
        } catch (e: Exception) {
            Log.w(TAG, "readAudioInfo extractor failed: ${e.message}")
        } finally {
            extractor.release()
        }
        // MediaExtractor rarely reports bitrate for MP3/AAC; the retriever does.
        if (out["bitrate"] == null) {
            val retriever = android.media.MediaMetadataRetriever()
            try {
                retriever.setDataSource(path)
                retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toIntOrNull()?.let { out["bitrate"] = it }
                if (out["durationMs"] == null) {
                    retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()?.let { out["durationMs"] = it }
                }
            } catch (e: Exception) {
                Log.w(TAG, "readAudioInfo retriever failed: ${e.message}")
            } finally {
                try { retriever.release() } catch (_: Exception) {}
            }
        }
        return out
    }

    private fun queryAudioFiles(): List<Map<String, Any?>> {
        val list = ArrayList<Map<String, Any?>>()
        val collection = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.SIZE,
            MediaStore.Audio.Media.DATE_MODIFIED,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.DATE_ADDED
        )
        val selection = "${MediaStore.Audio.Media.SIZE} > 0"
        try {
            contentResolver.query(collection, projection, selection, null, null)?.use { cursor ->
                val dataIdx = cursor.getColumnIndex(MediaStore.Audio.Media.DATA)
                val sizeIdx = cursor.getColumnIndex(MediaStore.Audio.Media.SIZE)
                val modIdx = cursor.getColumnIndex(MediaStore.Audio.Media.DATE_MODIFIED)
                val durIdx = cursor.getColumnIndex(MediaStore.Audio.Media.DURATION)
                val addedIdx = cursor.getColumnIndex(MediaStore.Audio.Media.DATE_ADDED)
                while (cursor.moveToNext()) {
                    val path = if (dataIdx >= 0) cursor.getString(dataIdx) else null
                    if (path.isNullOrBlank()) continue
                    val size = if (sizeIdx >= 0) cursor.getLong(sizeIdx) else 0L
                    val modified = if (modIdx >= 0) cursor.getLong(modIdx) else 0L
                    val duration = if (durIdx >= 0) cursor.getLong(durIdx) else 0L
                    val added = if (addedIdx >= 0) cursor.getLong(addedIdx) else 0L
                    list.add(mapOf("path" to path, "size" to size, "modified" to modified, "duration" to duration, "dateAdded" to added))
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "queryAudioFiles error: ${e.message}")
        }
        return list
    }

    /**
     * Initialize an Equalizer instance for a given audio session id. Returns true on success.
     * If sessionId==0 we still attempt to create an Equalizer on session 0 (global output).
     */
    /**
     * Applies bass boost / virtualizer strengths (0-1000) and a loudness gain
     * (millibels) to [sessionId]. An effect at 0 is disabled rather than
     * released so re-enabling is instant. Returns which effects the device
     * supports, so the UI can grey out unsupported ones.
     */
    private fun applySoundEffects(sessionId: Int, bass: Int, virt: Int, loudMb: Int): Map<String, Any> {
        val out = HashMap<String, Any>()
        if (sessionId <= 0) return out
        try {
            val bb = bassInstances.getOrPut(sessionId) { android.media.audiofx.BassBoost(0, sessionId) }
            out["bassSupported"] = bb.strengthSupported
            if (bb.strengthSupported && bass > 0) bb.setStrength(bass.coerceIn(0, 1000).toShort())
            bb.enabled = bass > 0
        } catch (e: Exception) {
            Log.w(TAG, "BassBoost unavailable: ${e.message}")
            out["bassSupported"] = false
        }
        try {
            val v = virtInstances.getOrPut(sessionId) { android.media.audiofx.Virtualizer(0, sessionId) }
            out["virtualizerSupported"] = v.strengthSupported
            if (v.strengthSupported && virt > 0) v.setStrength(virt.coerceIn(0, 1000).toShort())
            v.enabled = virt > 0
        } catch (e: Exception) {
            Log.w(TAG, "Virtualizer unavailable: ${e.message}")
            out["virtualizerSupported"] = false
        }
        try {
            val le = loudInstances.getOrPut(sessionId) { android.media.audiofx.LoudnessEnhancer(sessionId) }
            if (loudMb > 0) le.setTargetGain(loudMb.coerceIn(0, 1500))
            le.enabled = loudMb > 0
            out["loudnessSupported"] = true
        } catch (e: Exception) {
            Log.w(TAG, "LoudnessEnhancer unavailable: ${e.message}")
            out["loudnessSupported"] = false
        }
        return out
    }

    /** Where media audio is going right now: bluetooth / wired / speaker. */
    private fun currentOutputRoute(context: Context): Map<String, Any?> {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
        var wired: android.media.AudioDeviceInfo? = null
        for (d in am.getDevices(android.media.AudioManager.GET_DEVICES_OUTPUTS)) {
            when (d.type) {
                android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, 26 /* BLE_HEADSET */, 27 /* BLE_SPEAKER */ ->
                    return mapOf("type" to "bluetooth", "name" to (d.productName?.toString() ?: "Bluetooth"))
                android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET,
                android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                android.media.AudioDeviceInfo.TYPE_USB_HEADSET,
                android.media.AudioDeviceInfo.TYPE_USB_DEVICE -> if (wired == null) wired = d
            }
        }
        wired?.let { return mapOf("type" to "wired", "name" to (it.productName?.toString() ?: "Headphones")) }
        return mapOf("type" to "speaker", "name" to "Phone speaker")
    }

    private var routeCallbackRegistered = false

    /** Tells Dart when headphones / Bluetooth connect or disconnect. */
    private fun registerOutputRouteCallback(context: Context, channel: MethodChannel) {
        if (routeCallbackRegistered) return
        routeCallbackRegistered = true
        val am = context.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
        val handler = android.os.Handler(android.os.Looper.getMainLooper())
        am.registerAudioDeviceCallback(object : android.media.AudioDeviceCallback() {
            override fun onAudioDevicesAdded(added: Array<out android.media.AudioDeviceInfo>?) {
                channel.invokeMethod("onOutputChanged", currentOutputRoute(context))
            }
            override fun onAudioDevicesRemoved(removed: Array<out android.media.AudioDeviceInfo>?) {
                channel.invokeMethod("onOutputChanged", currentOutputRoute(context))
            }
        }, handler)
    }

    private fun initEqualizerForSession(sessionId: Int): Boolean {
        try {
            if (sessionId <= 0) {
                Log.e(TAG, "Invalid sessionId: $sessionId")
                return false
            }

            if (eqInstances.containsKey(sessionId)) return true

            eqInstances[sessionId] = EqEngine.create(sessionId)

            Log.d(TAG, "Equalizer initialized for session: $sessionId")

            return true
        } catch (e: Exception) {
            e.printStackTrace()
            return false
        }
    }

    /**
     * Helper to determine MIME type
     */
    private fun getMimeType(path: String): String {
        val extension = MimeTypeMap.getFileExtensionFromUrl(path)
        return if (extension != null) {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "audio/mpeg"
        } else {
            "audio/mpeg"
        }
    }

    /**
     * Inserts file into MediaStore (Android Q+) or Copies to Ringtones folder (Pre-Q)
     */
    private fun insertFileAsRingtone(srcFile: File, title: String): Uri? {
        val mimeType = getMimeType(srcFile.absolutePath)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, title)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(MediaStore.Audio.Media.IS_RINGTONE, true)
                put(MediaStore.Audio.Media.IS_NOTIFICATION, false)
                put(MediaStore.Audio.Media.IS_ALARM, false)
                put(MediaStore.Audio.Media.IS_MUSIC, false)
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_RINGTONES)
            }

            val newUri = contentResolver.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, values)
                ?: return null

            try {
                contentResolver.openOutputStream(newUri)?.use { os ->
                    FileInputStream(srcFile).use { fis ->
                        fis.copyTo(os)
                    }
                }
                return newUri
            } catch (e: IOException) {
                e.printStackTrace()
                contentResolver.delete(newUri, null, null)
                return null
            }

        } else {
            val ringtoneDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_RINGTONES)
            if (!ringtoneDir.exists()) ringtoneDir.mkdirs()

            val newFile = File(ringtoneDir, "$title.${srcFile.extension}")
            try {
                srcFile.copyTo(newFile, overwrite = true)
            } catch (e: Exception) {
                e.printStackTrace()
                return null
            }

            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DATA, newFile.absolutePath)
                put(MediaStore.MediaColumns.TITLE, title)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(MediaStore.Audio.Media.IS_RINGTONE, true)
                put(MediaStore.Audio.Media.IS_NOTIFICATION, false)
                put(MediaStore.Audio.Media.IS_ALARM, false)
                put(MediaStore.Audio.Media.IS_MUSIC, false)
            }

            val uri = contentResolver.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, values)
            if (uri == null) {
                val cursor = contentResolver.query(
                    MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                    arrayOf(MediaStore.MediaColumns._ID),
                    "${MediaStore.MediaColumns.DATA}=?",
                    arrayOf(newFile.absolutePath),
                    null
                )
                cursor?.use {
                    if (it.moveToFirst()) {
                        val id = it.getLong(it.getColumnIndexOrThrow(MediaStore.MediaColumns._ID))
                        return ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
                    }
                }
            }
            return uri
        }
    }
}
