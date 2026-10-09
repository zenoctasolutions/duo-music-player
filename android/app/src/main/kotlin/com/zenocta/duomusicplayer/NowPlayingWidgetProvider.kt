package com.zenocta.duomusicplayer

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.BitmapFactory
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Minimal home-screen "now playing" widget: album art, title/artist, and
 * play/pause/next/prev. The Dart side only ever WRITES state here (see
 * lib/home_widget_service.dart, called from songs_page.dart whenever the
 * current track or playback state changes). Button taps go through
 * WidgetActionActivity, which forwards a standard media-button key to
 * audio_service's MediaButtonReceiver (the same path hardware/Bluetooth
 * buttons and the notification use) while the app is alive, and opens the
 * app to run the action when the process has been killed.
 */
open class NowPlayingWidgetProvider : HomeWidgetProvider() {

    /** Layout for this widget style. Every style's layout contains the same
     *  view ids (art, title, artist, prev/play/next, root) so one binding
     *  routine serves all of them. */
    protected open val layoutId: Int = R.layout.now_playing_widget

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { widgetId ->
            val views = RemoteViews(context.packageName, layoutId).apply {
                val title = widgetData.getString("title", null)
                val artist = widgetData.getString("artist", null)
                // A dead engine can't be playing, whatever was last saved
                // (the app was cleared mid-song).
                val isPlaying = widgetData.getBoolean("isPlaying", false) &&
                    WidgetActionActivity.isEngineAlive()
                val coverPath = widgetData.getString("coverPath", null)

                setTextViewText(
                    R.id.widget_title,
                    if (!title.isNullOrEmpty()) title else "Duo Music Player",
                )
                setTextViewText(
                    R.id.widget_artist,
                    if (!artist.isNullOrEmpty()) artist else "Not playing",
                )

                val bitmap = coverPath?.let { BitmapFactory.decodeFile(it) }
                if (bitmap != null) {
                    setImageViewBitmap(R.id.widget_art, bitmap)
                } else {
                    setImageViewResource(R.id.widget_art, R.mipmap.ic_launcher)
                }

                setImageViewResource(
                    R.id.widget_play_pause,
                    if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                )

                setOnClickPendingIntent(R.id.widget_play_pause, actionPendingIntent(context, "play", 1))
                setOnClickPendingIntent(R.id.widget_next, actionPendingIntent(context, "next", 2))
                setOnClickPendingIntent(R.id.widget_previous, actionPendingIntent(context, "previous", 3))

                setOnClickPendingIntent(
                    R.id.widget_root,
                    HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java),
                )
            }

            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    /**
     * Routes through [WidgetActionActivity], which forwards a standard
     * media-button key to audio_service's MediaButtonReceiver while the app
     * is alive, or opens the app to run the action when the process was
     * killed (a bare broadcast then left the widget "playing" in silence).
     */
    private fun actionPendingIntent(context: Context, action: String, requestCode: Int): PendingIntent {
        val intent = Intent(context, WidgetActionActivity::class.java).apply {
            putExtra(WidgetActionActivity.EXTRA_ACTION, action)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
        }
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

/** 2×2 album-art tile: full-bleed cover with a title and transport row on top. */
class ArtTileWidgetProvider : NowPlayingWidgetProvider() {
    override val layoutId: Int = R.layout.now_playing_widget_tile
}

/** 4×2 large player: big cover, title/artist and larger controls. */
class LargePlayerWidgetProvider : NowPlayingWidgetProvider() {
    override val layoutId: Int = R.layout.now_playing_widget_large
}
