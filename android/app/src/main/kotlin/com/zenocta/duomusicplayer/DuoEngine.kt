package com.zenocta.duomusicplayer

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes as PlatformAudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Duo Mode: two independent players, one routed only to the left ear and
 * one only to the right ear, so two people sharing a pair of earphones can
 * each listen to their own song.
 *
 * just_audio has no per-channel pan control, so this runs its own pair of
 * Media3 ExoPlayers (the same engine just_audio uses under the hood). Each
 * player's audio sink carries an [EarRoutingAudioProcessor] that downmixes
 * the track to mono (so nothing recorded only on one channel of a stereo
 * mix is lost) and writes it to a single output channel, leaving the other
 * channel silent. Mixed together by the system mixer, the result is song A
 * in the left ear only and song B in the right ear only.
 *
 * All ExoPlayer access happens on the main thread (MethodChannel handlers
 * and Service callbacks both run there).
 */
@SuppressLint("UnsafeOptInUsageError")
object DuoEngine {
    private const val TAG = "DuoEngine"
    const val LEFT = "left"
    const val RIGHT = "right"

    class Side(routeLeft: Boolean) {
        val processor = EarRoutingAudioProcessor(routeLeft)
        var player: ExoPlayer? = null
        var titles: List<String> = emptyList()
    }

    private var appContext: Context? = null
    private val sides = mutableMapOf(LEFT to Side(true), RIGHT to Side(false))
    private var focusRequest: AudioFocusRequest? = null
    private var hasFocus = false
    private var resumeOnFocusGain = false

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                resumeOnFocusGain = false
                hasFocus = false
                pauseAll()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                resumeOnFocusGain = anyPlaying()
                pauseAll()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                sides.values.forEach { s -> s.player?.let { it.volume = it.volume * 0.3f } }
                resumeOnFocusGain = false
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                if (resumeOnFocusGain) sides.values.forEach { it.player?.play() }
                resumeOnFocusGain = false
                sides.values.forEach { s -> s.player?.let { it.volume = s.processor.userVolume } }
            }
        }
        DuoPlaybackService.refresh()
    }

    fun init(context: Context) {
        if (appContext == null) appContext = context.applicationContext
    }

    // ---------------------------------------------------------------- players

    private fun playerFor(sideKey: String): ExoPlayer {
        val side = sides[sideKey]!!
        side.player?.let { return it }
        val ctx = appContext!!
        val processor = side.processor
        val renderers = object : DefaultRenderersFactory(ctx) {
            override fun buildAudioSink(
                context: Context,
                enableFloatOutput: Boolean,
                enableAudioTrackPlaybackParams: Boolean
            ): AudioSink = DefaultAudioSink.Builder(context)
                .setAudioProcessors(arrayOf<AudioProcessor>(processor))
                .build()
        }
        val player = ExoPlayer.Builder(ctx, renderers)
            // Two players must never fight each other for focus; the engine
            // requests focus once on behalf of the pair instead.
            .setAudioAttributes(
                androidx.media3.common.AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                    .build(),
                false
            )
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_LOCAL)
            .build()
        player.addListener(object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) = DuoPlaybackService.refresh()
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) = DuoPlaybackService.refresh()
        })
        side.player = player
        return player
    }

    private fun anyPlaying() = sides.values.any { it.player?.isPlaying == true }

    private fun hasAnyQueue() = sides.values.any { (it.player?.mediaItemCount ?: 0) > 0 }

    fun pauseAll() {
        sides.values.forEach { it.player?.pause() }
    }

    fun toggleSide(key: String) {
        val p = sides[key]?.player ?: return
        if (p.isPlaying) p.pause() else playSides(listOf(key))
    }

    fun isSidePlaying(key: String) = sides[key]?.player?.isPlaying == true

    /** Split (default): one song per ear. Both ears: both songs mixed into both ears. */
    private var bothEars = false

    private fun playSides(keys: List<String>) {
        requestFocus()
        for (k in keys) {
            val p = sides[k]?.player ?: continue
            if (p.mediaItemCount == 0) continue
            if (p.playbackState == Player.STATE_ENDED) p.seekTo(0, 0)
            p.play()
        }
        startServiceIfNeeded()
    }

    fun stopAll() {
        sides.values.forEach {
            it.player?.release()
            it.player = null
            it.titles = emptyList()
        }
        abandonFocus()
        DuoPlaybackService.stop()
    }

    // ----------------------------------------------------------------- focus

    private fun requestFocus() {
        if (hasFocus) return
        val am = appContext?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val req = focusRequest ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    PlatformAudioAttributes.Builder()
                        .setUsage(PlatformAudioAttributes.USAGE_MEDIA)
                        .setContentType(PlatformAudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setOnAudioFocusChangeListener(focusListener)
                .build().also { focusRequest = it }
            am.requestAudioFocus(req)
        } else {
            @Suppress("DEPRECATION")
            am.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        }
        hasFocus = granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonFocus() {
        val am = appContext?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { am.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            am.abandonAudioFocus(focusListener)
        }
        hasFocus = false
    }

    // -------------------------------------------------------------- headphones

    /** Returns the name of the first connected personal-listening output, or null. */
    fun connectedHeadphones(context: Context): String? {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return null
        val personalTypes = setOf(
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            23, // TYPE_HEARING_AID (API 28)
            26, // TYPE_BLE_HEADSET (API 31)
        )
        for (d in am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
            if (d.type in personalTypes) {
                val name = d.productName?.toString()?.trim().orEmpty()
                return name.ifEmpty {
                    if (d.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP) "Bluetooth earbuds" else "Earphones"
                }
            }
        }
        return null
    }

    // ------------------------------------------------------------ notification

    fun titleFor(sideKey: String): String? {
        val side = sides[sideKey] ?: return null
        val p = side.player ?: return null
        if (p.mediaItemCount == 0) return null
        return side.titles.getOrNull(p.currentMediaItemIndex)
    }

    fun isAnyPlaying() = anyPlaying()

    /**
     * Android's accessibility "Mono audio" setting sums L+R before output,
     * which silently turns Duo Mode into both songs mixed in both ears — the
     * most common "songs are mixed together" complaint competitor apps get.
     */
    private fun monoAudioEnabled(context: Context): Boolean {
        val cr = context.contentResolver
        // AOSP / Pixel store it as System "master_mono"; Samsung One UI as
        // "mono_audio_db"; a few OEMs mirror it into Secure/Global.
        fun on(read: () -> Int): Boolean = try { read() == 1 } catch (e: Exception) { false }
        return on { android.provider.Settings.System.getInt(cr, "master_mono", 0) } ||
            on { android.provider.Settings.System.getInt(cr, "mono_audio_db", 0) } ||
            on { android.provider.Settings.Secure.getInt(cr, "master_mono", 0) } ||
            on { android.provider.Settings.Global.getInt(cr, "master_mono", 0) }
    }

    private fun startServiceIfNeeded() {
        val ctx = appContext ?: return
        if (!hasAnyQueue()) return
        try {
            val intent = Intent(ctx, DuoPlaybackService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(intent) else ctx.startService(intent)
        } catch (e: Exception) {
            // Playback still works while the app is in the foreground.
            Log.w(TAG, "Could not start Duo foreground service: $e")
        }
    }

    // ---------------------------------------------------------- method channel

    private fun sideState(key: String): Map<String, Any?> {
        val side = sides[key]!!
        val p = side.player
        if (p == null || p.mediaItemCount == 0) {
            return mapOf("path" to null, "volume" to side.processor.userVolume.toDouble())
        }
        val duration = p.duration
        return mapOf(
            "path" to p.currentMediaItem?.localConfiguration?.uri?.path,
            "index" to p.currentMediaItemIndex,
            "queueLength" to p.mediaItemCount,
            "playing" to p.isPlaying,
            "ended" to (p.playbackState == Player.STATE_ENDED),
            "positionMs" to p.currentPosition,
            "durationMs" to if (duration == C.TIME_UNSET) 0L else duration,
            "volume" to side.processor.userVolume.toDouble(),
            "shuffle" to p.shuffleModeEnabled,
            "repeat" to when (p.repeatMode) {
                Player.REPEAT_MODE_ONE -> "one"
                Player.REPEAT_MODE_ALL -> "all"
                else -> "off"
            },
        )
    }

    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        init(context)
        val key = call.argument<String>("side")
        try {
            when (call.method) {
                "getState" -> result.success(
                    mapOf(
                        "headphones" to connectedHeadphones(context),
                        "monoAudio" to monoAudioEnabled(context),
                        "bothEars" to bothEars,
                        LEFT to sideState(LEFT),
                        RIGHT to sideState(RIGHT),
                    )
                )
                "headphones" -> result.success(connectedHeadphones(context))
                "setQueue" -> {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    val titles = call.argument<List<String>>("titles") ?: emptyList()
                    val start = call.argument<Int>("startIndex") ?: 0
                    val autoPlay = call.argument<Boolean>("play") ?: true
                    val side = sides[key]!!
                    val p = playerFor(key!!)
                    side.titles = titles
                    p.setMediaItems(paths.map { MediaItem.fromUri(Uri.fromFile(File(it))) }, start.coerceIn(0, maxOf(0, paths.size - 1)), 0L)
                    p.prepare()
                    if (autoPlay) playSides(listOf(key)) else DuoPlaybackService.refresh()
                    result.success(null)
                }
                "play" -> {
                    playSides(if (key == null) listOf(LEFT, RIGHT) else listOf(key))
                    result.success(null)
                }
                "pause" -> {
                    if (key == null) pauseAll() else sides[key]?.player?.pause()
                    result.success(null)
                }
                "seek" -> {
                    val ms = (call.argument<Number>("positionMs") ?: 0).toLong()
                    sides[key]?.player?.seekTo(ms)
                    result.success(null)
                }
                "next" -> {
                    sides[key]?.player?.let { if (it.hasNextMediaItem()) it.seekToNextMediaItem() }
                    result.success(null)
                }
                "previous" -> {
                    sides[key]?.player?.let {
                        // Standard music-player behavior: restart the song if
                        // more than 3s in, otherwise go to the previous one.
                        if (it.currentPosition > 3000 || !it.hasPreviousMediaItem()) it.seekTo(0) else it.seekToPreviousMediaItem()
                    }
                    result.success(null)
                }
                "setVolume" -> {
                    val v = (call.argument<Number>("volume") ?: 1.0).toFloat().coerceIn(0f, 1f)
                    sides[key]?.let { s ->
                        s.processor.userVolume = v
                        s.player?.volume = v
                    }
                    result.success(null)
                }
                "setShuffle" -> {
                    sides[key]?.player?.shuffleModeEnabled = call.argument<Boolean>("enabled") ?: false
                    result.success(null)
                }
                "setRepeat" -> {
                    sides[key]?.player?.repeatMode = when (call.argument<String>("mode")) {
                        "one" -> Player.REPEAT_MODE_ONE
                        "all" -> Player.REPEAT_MODE_ALL
                        else -> Player.REPEAT_MODE_OFF
                    }
                    result.success(null)
                }
                "setBothEars" -> {
                    bothEars = call.argument<Boolean>("enabled") ?: false
                    sides.values.forEach { it.processor.bothEars = bothEars }
                    result.success(null)
                }
                "swapSides" -> {
                    // Swap which ear each song goes to without interrupting
                    // playback: the routing flag is read per audio buffer.
                    val l = sides[LEFT]!!
                    val r = sides[RIGHT]!!
                    l.processor.routeLeft = false
                    r.processor.routeLeft = true
                    sides[LEFT] = r
                    sides[RIGHT] = l
                    DuoPlaybackService.refresh()
                    result.success(null)
                }
                "openAccessibilitySettings" -> {
                    context.startActivity(
                        Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(null)
                }
                "stop" -> {
                    stopAll()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Duo ${call.method} failed", e)
            result.error("DUO_ERROR", e.message, null)
        }
    }
}

/**
 * Downmixes 16-bit PCM of any channel count to mono and writes it to only
 * the left or only the right channel of a stereo output. DefaultAudioSink
 * always converts decoder output to 16-bit integer PCM before custom
 * processors run (float output is disabled by default), so 16-bit is the
 * only input encoding this needs to handle.
 */
@SuppressLint("UnsafeOptInUsageError")
class EarRoutingAudioProcessor(@Volatile var routeLeft: Boolean) : BaseAudioProcessor() {
    /** Mirrors the player's volume so it survives audio-focus ducking. */
    @Volatile var userVolume: Float = 1f

    /** When true, the mono downmix goes to both ears instead of one. */
    @Volatile var bothEars: Boolean = false

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        return AudioProcessor.AudioFormat(inputAudioFormat.sampleRate, 2, C.ENCODING_PCM_16BIT)
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val channels = inputAudioFormat.channelCount
        val input = inputBuffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
        val frames = input.remaining() / (2 * channels)
        val out = replaceOutputBuffer(frames * 4).order(ByteOrder.LITTLE_ENDIAN)
        val left = routeLeft
        val both = bothEars
        for (i in 0 until frames) {
            var sum = 0
            for (c in 0 until channels) sum += input.short.toInt()
            val mono = (sum / channels).toShort()
            if (both) {
                // Two full-level songs summed per ear can clip; leave headroom.
                val shared = (mono * 0.7f).toInt().toShort()
                out.putShort(shared); out.putShort(shared)
            } else if (left) {
                out.putShort(mono); out.putShort(0)
            } else {
                out.putShort(0); out.putShort(mono)
            }
        }
        inputBuffer.position(inputBuffer.position() + frames * 2 * channels)
        out.flip()
    }
}
