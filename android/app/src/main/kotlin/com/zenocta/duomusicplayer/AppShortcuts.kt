package com.zenocta.duomusicplayer

import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.os.Build
import android.view.KeyEvent

/**
 * Launcher (long-press icon) shortcuts. Published dynamically rather than via
 * res/xml/shortcuts.xml because static shortcuts need a literal targetPackage,
 * which breaks the debug build's ".dev" applicationIdSuffix; here the intent
 * targets MainActivity by class so it works for every build variant.
 *
 * Flow: shortcut -> MainActivity (onCreate / onNewIntent) -> [handle].
 *  - SHUFFLE_ALL / SEARCH: stored in [pendingShortcut]; Dart reads it once via
 *    the 'music_app/system' channel method "takeShortcutAction"
 *    (lib/shortcuts/shortcut_actions.dart).
 *  - RESUME: reuses the existing widget "play" path. Engine alive -> a media
 *    play/pause key; process cold -> returned as the pending *widget* action
 *    "play", which songs_page already consumes at startup.
 */
object AppShortcuts {
    const val ACTION_SHUFFLE_ALL = "zen.action.SHUFFLE_ALL"
    const val ACTION_SEARCH = "zen.action.SEARCH"
    const val ACTION_RESUME = "zen.action.RESUME"

    @Volatile var pendingShortcut: String? = null

    /** Returns a widget-action string to queue (cold resume), else null. */
    fun handle(context: Context, intent: Intent?): String? {
        val action = intent?.action ?: return null
        var widgetAction: String? = null
        when (action) {
            ACTION_SHUFFLE_ALL -> pendingShortcut = "shuffle_all"
            ACTION_SEARCH -> pendingShortcut = "search"
            ACTION_RESUME -> {
                if (WidgetActionActivity.isEngineAlive()) {
                    WidgetActionActivity.sendMediaButton(context.applicationContext, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
                } else {
                    widgetAction = "play"
                }
            }
            else -> return null
        }
        // Consumed: don't re-run on activity recreation.
        intent.action = Intent.ACTION_MAIN
        return widgetAction
    }

    fun publish(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return
        try {
            val sm = context.getSystemService(ShortcutManager::class.java) ?: return
            fun make(id: String, action: String, short: Int, long: Int, icon: Int) =
                ShortcutInfo.Builder(context, id)
                    .setShortLabel(context.getString(short))
                    .setLongLabel(context.getString(long))
                    .setIcon(Icon.createWithResource(context, icon))
                    .setIntent(Intent(context, MainActivity::class.java).apply {
                        this.action = action
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                    })
                    .build()
            sm.dynamicShortcuts = listOf(
                make("shuffle_all", ACTION_SHUFFLE_ALL, R.string.shortcut_shuffle_short, R.string.shortcut_shuffle_long, R.drawable.ic_shortcut_shuffle),
                make("search", ACTION_SEARCH, R.string.shortcut_search_short, R.string.shortcut_search_long, R.drawable.ic_shortcut_search),
                make("resume", ACTION_RESUME, R.string.shortcut_resume_short, R.string.shortcut_resume_long, R.drawable.ic_shortcut_play),
            )
        } catch (_: Exception) {
            // Shortcuts are a convenience; never crash the app over them.
        }
    }
}
