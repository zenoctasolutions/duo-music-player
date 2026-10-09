package com.zenocta.duomusicplayer

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Verifies Duo Mode's per-ear routing: song audio lands in exactly one output channel. */
class EarRoutingAudioProcessorTest {

    private fun run(processor: EarRoutingAudioProcessor, channels: Int, samples: ShortArray): ShortArray {
        processor.configure(AudioProcessor.AudioFormat(44100, channels, C.ENCODING_PCM_16BIT))
        processor.flush()
        val input = ByteBuffer.allocateDirect(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        samples.forEach { input.putShort(it) }
        input.flip()
        processor.queueInput(input)
        assertEquals("input fully consumed", 0, input.remaining())
        val out = processor.output.order(ByteOrder.LITTLE_ENDIAN)
        return ShortArray(out.remaining() / 2) { out.short }
    }

    @Test fun stereoToLeftEarOnly() {
        // Two stereo frames: (L=1000, R=3000), (L=-2000, R=-4000)
        val out = run(EarRoutingAudioProcessor(routeLeft = true), 2, shortArrayOf(1000, 3000, -2000, -4000))
        assertEquals(listOf<Short>(2000, 0, -3000, 0), out.toList())
    }

    @Test fun stereoToRightEarOnly() {
        val out = run(EarRoutingAudioProcessor(routeLeft = false), 2, shortArrayOf(1000, 3000, -2000, -4000))
        assertEquals(listOf<Short>(0, 2000, 0, -3000), out.toList())
    }

    @Test fun monoInputIsUpmixedToOneEar() {
        val out = run(EarRoutingAudioProcessor(routeLeft = true), 1, shortArrayOf(1234, -1234))
        assertEquals(listOf<Short>(1234, 0, -1234, 0), out.toList())
    }

    @Test fun swapTakesEffectWithoutReconfigure() {
        val p = EarRoutingAudioProcessor(routeLeft = true)
        run(p, 2, shortArrayOf(100, 100))
        p.routeLeft = false
        val input = ByteBuffer.allocateDirect(4).order(ByteOrder.LITTLE_ENDIAN).putShort(100).putShort(100)
        input.flip()
        p.queueInput(input)
        val out = p.output.order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(listOf<Short>(0, 100), listOf(out.short, out.short))
    }

    @Test fun bothEarsModeFeedsBothChannelsWithHeadroom() {
        val p = EarRoutingAudioProcessor(routeLeft = true).apply { bothEars = true }
        val out = run(p, 2, shortArrayOf(1000, 1000))
        assertEquals(listOf<Short>(700, 700), out.toList())
    }

    @Test fun maxAmplitudeDoesNotOverflow() {
        val out = run(EarRoutingAudioProcessor(routeLeft = false), 2, shortArrayOf(Short.MAX_VALUE, Short.MAX_VALUE, Short.MIN_VALUE, Short.MIN_VALUE))
        assertEquals(listOf(0.toShort(), Short.MAX_VALUE, 0.toShort(), Short.MIN_VALUE), out.toList())
    }
}
