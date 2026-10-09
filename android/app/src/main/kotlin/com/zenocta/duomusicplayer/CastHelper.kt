package com.zenocta.duomusicplayer

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.mediarouter.media.MediaRouteSelector
import androidx.mediarouter.media.MediaRouter
import com.google.android.gms.cast.CastMediaControlIntent
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.MediaStatus
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.SessionProvider
import com.google.android.gms.cast.framework.media.RemoteMediaClient
import com.google.android.gms.common.images.WebImage
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

/** Uses Google's Default Media Receiver — no receiver app registration needed. */
class CastOptionsProvider : OptionsProvider {
    override fun getCastOptions(context: Context): CastOptions = CastOptions.Builder()
        .setReceiverApplicationId(CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID)
        .build()

    override fun getAdditionalSessionProviders(context: Context): List<SessionProvider>? = null
}

/**
 * Chromecast support ("music_app/cast"):
 *  * device discovery through MediaRouter, reported to Dart (which shows its
 *    own picker — no AppCompat dialog needed in this FlutterActivity);
 *  * a tiny LAN HTTP server with Range support that streams the local file
 *    (and its cover) to the Cast device, since receivers fetch by URL;
 *  * load / play / pause / seek / volume on the RemoteMediaClient, with
 *    status pushed back to Dart ("onStatus") so it can auto-advance.
 * All Cast/MediaRouter calls happen on the main thread.
 */
object CastHelper {
    private const val TAG = "CastHelper"
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var castContext: CastContext? = null
    private var router: MediaRouter? = null
    private val selector: MediaRouteSelector by lazy {
        MediaRouteSelector.Builder()
            .addControlCategory(CastMediaControlIntent.categoryForCast(CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID))
            .build()
    }

    private val routeCallback = object : MediaRouter.Callback() {
        override fun onRouteAdded(r: MediaRouter, route: MediaRouter.RouteInfo) = pushRoutes()
        override fun onRouteRemoved(r: MediaRouter, route: MediaRouter.RouteInfo) = pushRoutes()
        override fun onRouteChanged(r: MediaRouter, route: MediaRouter.RouteInfo) = pushRoutes()
    }

    private val mediaCallback = object : RemoteMediaClient.Callback() {
        override fun onStatusUpdated() = pushStatus()
    }

    private val sessionListener = object : SessionManagerListener<CastSession> {
        override fun onSessionStarted(session: CastSession, sessionId: String) {
            session.remoteMediaClient?.registerCallback(mediaCallback)
            channel?.invokeMethod("onConnected", mapOf("device" to (session.castDevice?.friendlyName ?: "Cast device")))
        }
        override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) = onSessionStarted(session, "")
        override fun onSessionEnded(session: CastSession, error: Int) {
            session.remoteMediaClient?.unregisterCallback(mediaCallback)
            channel?.invokeMethod("onDisconnected", null)
        }
        override fun onSessionStartFailed(session: CastSession, error: Int) {
            channel?.invokeMethod("onError", mapOf("message" to "Couldn't connect to the device ($error)"))
        }
        override fun onSessionStarting(session: CastSession) {}
        override fun onSessionEnding(session: CastSession) {}
        override fun onSessionResuming(session: CastSession, sessionId: String) {}
        override fun onSessionResumeFailed(session: CastSession, error: Int) {}
        override fun onSessionSuspended(session: CastSession, reason: Int) {}
    }

    fun register(context: Context, ch: MethodChannel) {
        channel = ch
        ch.setMethodCallHandler { call, result -> handle(context.applicationContext, call, result) }
    }

    private fun ensureInit(context: Context): Boolean {
        if (castContext != null) return true
        return try {
            @Suppress("DEPRECATION")
            castContext = CastContext.getSharedInstance(context)
            castContext!!.sessionManager.addSessionManagerListener(sessionListener, CastSession::class.java)
            router = MediaRouter.getInstance(context)
            true
        } catch (e: Exception) {
            // No Google Play services / Cast unsupported on this device.
            Log.w(TAG, "Cast unavailable: ${e.message}")
            false
        }
    }

    private val session: CastSession? get() = castContext?.sessionManager?.currentCastSession
    private val client: RemoteMediaClient? get() = session?.remoteMediaClient

    private fun routes(): List<Map<String, Any>> {
        val r = router ?: return emptyList()
        return r.routes
            .filter { !it.isDefault && it.isEnabled && it.matchesSelector(selector) }
            .map { mapOf("id" to it.id, "name" to it.name, "description" to (it.description ?: "")) }
    }

    private fun pushRoutes() {
        channel?.invokeMethod("onRoutes", routes())
    }

    private fun pushStatus() {
        val c = client ?: return
        val status = c.mediaStatus
        channel?.invokeMethod("onStatus", mapOf(
            "playerState" to when (status?.playerState) {
                MediaStatus.PLAYER_STATE_PLAYING -> "playing"
                MediaStatus.PLAYER_STATE_PAUSED -> "paused"
                MediaStatus.PLAYER_STATE_BUFFERING, MediaStatus.PLAYER_STATE_LOADING -> "buffering"
                else -> "idle"
            },
            "finished" to (status?.playerState == MediaStatus.PLAYER_STATE_IDLE && status.idleReason == MediaStatus.IDLE_REASON_FINISHED),
            "positionMs" to c.approximateStreamPosition,
            "durationMs" to c.streamDuration,
            "volume" to (session?.volume ?: 1.0),
        ))
    }

    private fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "isAvailable" -> result.success(ensureInit(context))
                "startDiscovery" -> {
                    if (!ensureInit(context)) return result.success(false)
                    router!!.addCallback(selector, routeCallback, MediaRouter.CALLBACK_FLAG_REQUEST_DISCOVERY)
                    pushRoutes()
                    result.success(true)
                }
                "stopDiscovery" -> {
                    router?.removeCallback(routeCallback)
                    result.success(null)
                }
                "connect" -> {
                    val id = call.argument<String>("id")
                    val route = router?.routes?.firstOrNull { it.id == id }
                    if (route == null) result.error("NO_ROUTE", "Device not found", null)
                    else {
                        router!!.selectRoute(route)
                        result.success(true)
                    }
                }
                "disconnect" -> {
                    castContext?.sessionManager?.endCurrentSession(true)
                    MediaServer.stop()
                    result.success(null)
                }
                "isConnected" -> result.success(session?.isConnected == true)
                "load" -> {
                    val c = client ?: return result.error("NOT_CONNECTED", "No cast session", null)
                    val path = call.argument<String>("path")!!
                    val cover = call.argument<String>("coverPath")
                    val base = MediaServer.ensureStarted() ?: return result.error("NO_WIFI", "Connect to the same Wi-Fi as the Cast device", null)
                    val url = base + MediaServer.publish(path)
                    val md = MediaMetadata(MediaMetadata.MEDIA_TYPE_MUSIC_TRACK).apply {
                        putString(MediaMetadata.KEY_TITLE, call.argument<String>("title") ?: File(path).nameWithoutExtension)
                        call.argument<String>("artist")?.let { putString(MediaMetadata.KEY_ARTIST, it) }
                        call.argument<String>("album")?.let { putString(MediaMetadata.KEY_ALBUM_TITLE, it) }
                        if (cover != null && File(cover).exists()) addImage(WebImage(Uri.parse(base + MediaServer.publish(cover))))
                    }
                    val info = MediaInfo.Builder(url)
                        .setStreamType(MediaInfo.STREAM_TYPE_BUFFERED)
                        .setContentType(MediaServer.mimeFor(path))
                        .setMetadata(md)
                        .build()
                    c.load(MediaLoadRequestData.Builder()
                        .setMediaInfo(info)
                        .setAutoplay(call.argument<Boolean>("autoplay") ?: true)
                        .setCurrentTime((call.argument<Number>("positionMs") ?: 0).toLong())
                        .build())
                    result.success(true)
                }
                "play" -> { client?.play(); result.success(null) }
                "pause" -> { client?.pause(); result.success(null) }
                "seek" -> {
                    @Suppress("DEPRECATION")
                    client?.seek((call.argument<Number>("positionMs") ?: 0).toLong())
                    result.success(null)
                }
                "setVolume" -> { session?.volume = (call.argument<Number>("volume") ?: 1.0).toDouble(); result.success(null) }
                "status" -> { pushStatus(); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(TAG, "${call.method} failed", e)
            result.error("CAST_ERROR", e.message, null)
        }
    }
}

/**
 * Minimal HTTP/1.1 file server for the Cast receiver: GET/HEAD with Range
 * support, serving only files explicitly published under a random token.
 */
object MediaServer {
    private var server: ServerSocket? = null
    private var baseUrl: String? = null
    private val published = ConcurrentHashMap<String, String>()

    fun mimeFor(path: String): String {
        val ext = File(path).extension.lowercase()
        return when (ext) {
            "mp3" -> "audio/mpeg"
            "m4a", "aac", "mp4" -> "audio/mp4"
            "flac" -> "audio/flac"
            "ogg", "oga" -> "audio/ogg"
            "opus" -> "audio/ogg"
            "wav" -> "audio/wav"
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        }
    }

    /** Returns the relative URL path for [file] (e.g. "abcd.mp3"). */
    fun publish(file: String): String {
        val existing = published.entries.firstOrNull { it.value == file }?.key
        if (existing != null) return existing
        val token = UUID.randomUUID().toString().replace("-", "") + "." + File(file).extension
        published[token] = file
        return token
    }

    private fun lanAddress(): String? {
        for (ni in NetworkInterface.getNetworkInterfaces()) {
            if (!ni.isUp || ni.isLoopback) continue
            for (addr in ni.inetAddresses) {
                if (addr is Inet4Address && addr.isSiteLocalAddress) return addr.hostAddress
            }
        }
        return null
    }

    @Synchronized
    fun ensureStarted(): String? {
        baseUrl?.let { return it }
        val ip = lanAddress() ?: return null
        val ss = ServerSocket(0)
        server = ss
        baseUrl = "http://$ip:${ss.localPort}/"
        thread(name = "zen-cast-server", isDaemon = true) {
            while (!ss.isClosed) {
                val socket = try { ss.accept() } catch (e: Exception) { break }
                thread(isDaemon = true) { serve(socket) }
            }
        }
        return baseUrl
    }

    @Synchronized
    fun stop() {
        try { server?.close() } catch (_: Exception) {}
        server = null
        baseUrl = null
        published.clear()
    }

    private fun serve(socket: Socket) {
        socket.use { s ->
            try {
                val input = s.getInputStream().bufferedReader()
                val requestLine = input.readLine() ?: return
                val parts = requestLine.split(" ")
                if (parts.size < 2) return
                val method = parts[0]
                val token = parts[1].trimStart('/').substringBefore('?')
                var range: String? = null
                while (true) {
                    val line = input.readLine() ?: break
                    if (line.isEmpty()) break
                    if (line.startsWith("Range:", ignoreCase = true)) range = line.substringAfter(":").trim()
                }
                val out = s.getOutputStream()
                val path = published[token]
                val file = path?.let { File(it) }
                if (file == null || !file.exists()) {
                    out.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                    return
                }
                val len = file.length()
                var start = 0L
                var end = len - 1
                val partial = range?.startsWith("bytes=") == true
                if (partial) {
                    val spec = range!!.removePrefix("bytes=").split("-")
                    start = spec.getOrNull(0)?.toLongOrNull() ?: 0L
                    end = spec.getOrNull(1)?.takeIf { it.isNotEmpty() }?.toLongOrNull() ?: (len - 1)
                    end = end.coerceAtMost(len - 1)
                }
                val count = (end - start + 1).coerceAtLeast(0)
                val header = StringBuilder()
                    .append(if (partial) "HTTP/1.1 206 Partial Content\r\n" else "HTTP/1.1 200 OK\r\n")
                    .append("Content-Type: ${mimeFor(file.path)}\r\n")
                    .append("Content-Length: $count\r\n")
                    .append("Accept-Ranges: bytes\r\n")
                    .append("Access-Control-Allow-Origin: *\r\n")
                    .apply { if (partial) append("Content-Range: bytes $start-$end/$len\r\n") }
                    .append("Connection: close\r\n\r\n")
                out.write(header.toString().toByteArray())
                if (method == "HEAD") return
                RandomAccessFile(file, "r").use { raf ->
                    raf.seek(start)
                    val buf = ByteArray(64 * 1024)
                    var remaining = count
                    while (remaining > 0) {
                        val n = raf.read(buf, 0, minOf(buf.size.toLong(), remaining).toInt())
                        if (n <= 0) break
                        out.write(buf, 0, n)
                        remaining -= n
                    }
                }
                out.flush()
            } catch (_: Exception) {
                // client disconnected mid-stream — normal for seeking receivers
            }
        }
    }
}
