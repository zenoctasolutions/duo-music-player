package com.zenocta.duomusicplayer

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.KeyEvent
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.FlutterEngineCache

/**
 * Invisible trampoline behind the home-screen widget's transport buttons.
 *
 * A media-button broadcast only works while the Flutter engine (and so the
 * Dart player) is alive. After the app is cleared from recents / the
 * process is killed, the broadcast used to start audio_service's service
 * with nothing loaded: the widget flipped to "playing" but no audio came
 * out. So:
 *  - engine alive -> forward the key exactly as before (no UI shown);
 *  - engine gone  -> open the app with the action, which Dart runs once
 *    the library/queue are ready (songs_page `_consumeWidgetLaunchAction`).
 *
 * An Activity (not a BroadcastReceiver) because starting the app UI from a
 * background receiver is blocked on Android 10+, while a widget tap is
 * allowed to start an activity.
 */
class WidgetActionActivity : Activity() {

    companion object {
        const val EXTRA_ACTION = "zen_widget_action"

        fun isEngineAlive(): Boolean =
            FlutterEngineCache.getInstance().get(AudioServicePlugin.getFlutterEngineId()) != null

        fun keyCodeFor(action: String?): Int? = when (action) {
            "play" -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
            "next" -> KeyEvent.KEYCODE_MEDIA_NEXT
            "previous" -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
            else -> null
        }

        fun sendMediaButton(context: Context, keyCode: Int) {
            // Same intent the widget used to broadcast directly: explicit
            // package so API 26+ delivers it to audio_service's
            // MediaButtonReceiver, which hands it to the MediaSession.
            context.sendBroadcast(Intent(Intent.ACTION_MEDIA_BUTTON).apply {
                setPackage(context.packageName)
                putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
            })
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val action = intent?.getStringExtra(EXTRA_ACTION)
        var keyCode = keyCodeFor(action)
        if (action == "play") {
            // Explicit PLAY / PAUSE (matching the icon the widget shows)
            // instead of the PLAY_PAUSE toggle: when the tap has to restart
            // audio_service's stopped service the key can be delivered
            // twice, and two toggles played and immediately paused again.
            val showsPlaying = getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)
                .getBoolean("isPlaying", false) && isEngineAlive()
            keyCode = if (showsPlaying) KeyEvent.KEYCODE_MEDIA_PAUSE else KeyEvent.KEYCODE_MEDIA_PLAY
        }
        if (keyCode != null) {
            if (isEngineAlive()) {
                sendMediaButton(applicationContext, keyCode)
            } else {
                startActivity(Intent(this, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    putExtra(EXTRA_ACTION, action)
                })
            }
        }
        finish()
        overridePendingTransition(0, 0)
    }
}
