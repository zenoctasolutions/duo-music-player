package com.zenocta.duomusicplayer

import android.annotation.TargetApi
import android.media.audiofx.DynamicsProcessing
import android.media.audiofx.Equalizer
import android.os.Build
import android.util.Log

/**
 * Equalizer backend used by the "music_app/equalizer" channel. The Dart EQ
 * screen draws whatever bands this reports, so switching engines needs no
 * UI change.
 *  * [TenBandEqEngine] — 10 bands (31 Hz … 16 kHz, ±12 dB) on Android 9+
 *    via DynamicsProcessing's pre-EQ stage.
 *  * [SystemEqEngine]  — the device's own android.media.audiofx.Equalizer
 *    (usually 5 bands) as the fallback.
 * Levels are in millibels throughout, like the platform Equalizer API.
 */
interface EqEngine {
    var enabled: Boolean
    val bandLevelRange: IntArray
    val centerFreqsHz: List<Int>
    val presetNames: List<String>
    fun usePreset(index: Int)
    fun getBandLevel(band: Int): Int
    fun setBandLevel(band: Int, levelMb: Int)
    fun release()

    companion object {
        private const val TAG = "EqEngine"

        fun create(sessionId: Int): EqEngine {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                try {
                    return TenBandEqEngine(sessionId)
                } catch (e: Exception) {
                    Log.w(TAG, "10-band EQ unavailable, using system Equalizer: ${e.message}")
                }
            }
            return SystemEqEngine(sessionId)
        }
    }
}

class SystemEqEngine(sessionId: Int) : EqEngine {
    private val eq = Equalizer(0, sessionId).apply { enabled = true }

    override var enabled: Boolean
        get() = eq.enabled
        set(v) { eq.enabled = v }
    override val bandLevelRange: IntArray get() = eq.bandLevelRange.map { it.toInt() }.toIntArray()
    override val centerFreqsHz: List<Int> get() = (0 until eq.numberOfBands).map { eq.getCenterFreq(it.toShort()) / 1000 }
    override val presetNames: List<String>
        get() = try {
            (0 until eq.numberOfPresets).map { eq.getPresetName(it.toShort()) }
        } catch (e: Exception) {
            emptyList()
        }

    override fun usePreset(index: Int) = eq.usePreset(index.toShort())
    override fun getBandLevel(band: Int): Int = eq.getBandLevel(band.toShort()).toInt()
    override fun setBandLevel(band: Int, levelMb: Int) {
        eq.enabled = true
        eq.setBandLevel(band.toShort(), levelMb.toShort())
    }

    override fun release() = eq.release()
}

@TargetApi(Build.VERSION_CODES.P)
class TenBandEqEngine(sessionId: Int) : EqEngine {
    companion object {
        val CENTERS = listOf(31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000)

        // DynamicsProcessing EQ bands are defined by their UPPER cutoff:
        // the geometric midpoint to the next centre (last band to 20 kHz).
        private val CUTOFFS = floatArrayOf(44f, 88f, 177f, 354f, 707f, 1414f, 2828f, 5657f, 11314f, 20000f)
        private const val RANGE_MB = 1200

        // Same names and order as Android's built-in presets, so saved preset
        // indices and the Dart-side display names stay consistent. Gains in dB.
        val PRESETS: List<Pair<String, IntArray>> = listOf(
            "Normal" to intArrayOf(3, 2, 1, 0, 0, 0, 0, 1, 2, 3),
            "Classical" to intArrayOf(5, 4, 3, 2, -1, -1, 0, 2, 3, 4),
            "Dance" to intArrayOf(6, 5, 3, 1, 0, -1, 1, 3, 4, 4),
            "Flat" to intArrayOf(0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
            "Folk" to intArrayOf(3, 2, 1, 0, 0, 0, 1, 2, 2, 1),
            "Heavy Metal" to intArrayOf(4, 3, 2, 1, -1, 0, 2, 3, 4, 4),
            "Hip Hop" to intArrayOf(5, 4, 3, 1, 0, -1, 0, 1, 2, 3),
            "Jazz" to intArrayOf(4, 3, 1, 2, -1, -1, 0, 1, 3, 4),
            "Pop" to intArrayOf(-1, 0, 1, 3, 4, 3, 1, 0, -1, -1),
            "Rock" to intArrayOf(5, 4, 3, 1, -1, -1, 1, 3, 4, 5),
        )
    }

    private val levels = IntArray(CENTERS.size)
    private val dp: DynamicsProcessing

    init {
        val config = DynamicsProcessing.Config.Builder(
            DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION,
            2,               // channels
            true, CENTERS.size, // pre-EQ in use, 10 bands
            false, 0,        // no multiband compressor
            false, 0,        // no post-EQ
            false            // no limiter
        ).build()
        dp = DynamicsProcessing(0, sessionId, config)
        for (b in CENTERS.indices) applyBand(b)
        dp.enabled = true
    }

    private fun applyBand(band: Int) {
        dp.setPreEqBandAllChannelsTo(band, DynamicsProcessing.EqBand(true, CUTOFFS[band], levels[band] / 100f))
    }

    override var enabled: Boolean
        get() = dp.enabled
        set(v) { dp.enabled = v }
    override val bandLevelRange: IntArray get() = intArrayOf(-RANGE_MB, RANGE_MB)
    override val centerFreqsHz: List<Int> get() = CENTERS
    override val presetNames: List<String> get() = PRESETS.map { it.first }

    override fun usePreset(index: Int) {
        val gains = PRESETS.getOrNull(index)?.second ?: return
        for (b in CENTERS.indices) {
            levels[b] = gains[b] * 100
            applyBand(b)
        }
    }

    override fun getBandLevel(band: Int): Int = levels.getOrElse(band) { 0 }
    override fun setBandLevel(band: Int, levelMb: Int) {
        if (band !in CENTERS.indices) return
        levels[band] = levelMb.coerceIn(-RANGE_MB, RANGE_MB)
        dp.enabled = true
        applyBand(band)
    }

    override fun release() = dp.release()
}
