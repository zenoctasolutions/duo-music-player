package com.zenocta.duomusicplayer

import android.app.Activity
import android.app.RecoverableSecurityException
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.lang.ref.WeakReference

/**
 * Native half of the tag editor ("music_app/tags"):
 *  * requestWriteAccess — asks the user (system dialog) for permission to
 *    modify a song file the app doesn't own: MediaStore.createWriteRequest
 *    on Android 11+, RecoverableSecurityException on Android 10, nothing
 *    needed on 9 and below (legacy storage permission).
 *  * replaceFileContents — overwrites the song with the re-tagged copy
 *    ffmpeg produced (through the ContentResolver on 10+), then rescans
 *    it so MediaStore/other apps see the new tags.
 *  * pickImage — system Photo Picker (no storage/photos permission), the
 *    chosen image is copied to the cache and its path returned.
 * Activity results are routed here from MainActivity.onActivityResult.
 */
object TagWriteHelper {
    private const val TAG = "TagWriteHelper"
    private const val REQ_WRITE = 7401
    private const val REQ_PICK_IMAGE = 7402

    private var activityRef: WeakReference<Activity>? = null
    private var pendingWrite: MethodChannel.Result? = null
    private var pendingPick: MethodChannel.Result? = null

    fun attach(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    private val activity: Activity? get() = activityRef?.get()

    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "requestWriteAccess" -> requestWriteAccess(context, call.argument<String>("path")!!, result)
                "replaceFileContents" -> {
                    val path = call.argument<String>("path")!!
                    val temp = call.argument<String>("tempPath")!!
                    Thread {
                        val ok = replaceFileContents(context, path, temp)
                        activity?.runOnUiThread { result.success(ok) } ?: result.success(ok)
                    }.start()
                }
                "pickImage" -> pickImage(result)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(TAG, "${call.method} failed", e)
            result.error("TAG_ERROR", e.message, null)
        }
    }

    private fun contentUriFor(context: Context, path: String): Uri? {
        val projection = arrayOf(MediaStore.Audio.Media._ID)
        context.contentResolver.query(
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, projection,
            "${MediaStore.Audio.Media.DATA}=?", arrayOf(path), null
        )?.use { c ->
            if (c.moveToFirst()) {
                return ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, c.getLong(0))
            }
        }
        return null
    }

    private fun requestWriteAccess(context: Context, path: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(File(path).canWrite())
            return
        }
        val uri = contentUriFor(context, path)
        if (uri == null) {
            result.error("NOT_INDEXED", "File is not in the media library", null)
            return
        }
        val act = activity
        if (act == null) {
            result.error("NO_ACTIVITY", "App is not in the foreground", null)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val pi = MediaStore.createWriteRequest(context.contentResolver, listOf(uri))
            pendingWrite?.success(false)
            pendingWrite = result
            act.startIntentSenderForResult(pi.intentSender, REQ_WRITE, null, 0, 0, 0)
            return
        }
        // Android 10: probe; a RecoverableSecurityException carries the consent dialog.
        try {
            context.contentResolver.openFileDescriptor(uri, "rw")?.close()
            result.success(true)
        } catch (e: RecoverableSecurityException) {
            pendingWrite?.success(false)
            pendingWrite = result
            act.startIntentSenderForResult(e.userAction.actionIntent.intentSender, REQ_WRITE, null, 0, 0, 0)
        } catch (e: SecurityException) {
            result.success(false)
        }
    }

    private fun replaceFileContents(context: Context, path: String, tempPath: String): Boolean {
        val temp = File(tempPath)
        if (!temp.exists() || temp.length() == 0L) return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val uri = contentUriFor(context, path) ?: return false
                context.contentResolver.openOutputStream(uri, "wt")?.use { out ->
                    FileInputStream(temp).use { it.copyTo(out) }
                } ?: return false
            } else {
                FileOutputStream(File(path), false).use { out ->
                    FileInputStream(temp).use { it.copyTo(out) }
                }
            }
            MediaScannerConnection.scanFile(context, arrayOf(path), null, null)
            true
        } catch (e: Exception) {
            Log.e(TAG, "replaceFileContents failed: ${e.message}")
            false
        } finally {
            temp.delete()
        }
    }

    private fun pickImage(result: MethodChannel.Result) {
        val act = activity
        if (act == null) {
            result.error("NO_ACTIVITY", "App is not in the foreground", null)
            return
        }
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Intent(MediaStore.ACTION_PICK_IMAGES).setType("image/*")
        } else {
            Intent(Intent.ACTION_GET_CONTENT).setType("image/*").addCategory(Intent.CATEGORY_OPENABLE)
        }
        pendingPick?.success(null)
        pendingPick = result
        act.startActivityForResult(intent, REQ_PICK_IMAGE)
    }

    /** Returns true when the request code belonged to this helper. */
    fun onActivityResult(context: Context, requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        when (requestCode) {
            REQ_WRITE -> {
                pendingWrite?.success(resultCode == Activity.RESULT_OK)
                pendingWrite = null
                return true
            }
            REQ_PICK_IMAGE -> {
                val res = pendingPick
                pendingPick = null
                val uri = data?.data
                if (resultCode != Activity.RESULT_OK || uri == null) {
                    res?.success(null)
                    return true
                }
                Thread {
                    val out = try {
                        val mime = context.contentResolver.getType(uri) ?: "image/jpeg"
                        val ext = if (mime.contains("png")) "png" else "jpg"
                        val f = File(context.cacheDir, "cover_pick_${System.currentTimeMillis()}.$ext")
                        context.contentResolver.openInputStream(uri)?.use { input ->
                            FileOutputStream(f).use { input.copyTo(it) }
                        }
                        f.absolutePath
                    } catch (e: Exception) {
                        Log.e(TAG, "pickImage copy failed: ${e.message}")
                        null
                    }
                    activity?.runOnUiThread { res?.success(out) } ?: res?.success(out)
                }.start()
                return true
            }
        }
        return false
    }
}
