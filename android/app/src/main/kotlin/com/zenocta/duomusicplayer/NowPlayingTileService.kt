package com.zenocta.duomusicplayer

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.view.KeyEvent

/**
 * Quick Settings tile: shows the current title (from the same
 * HomeWidgetPreferences the widget uses) and toggles play/pause. With no live
 * engine (app killed) a tap opens the app and resumes via the widget "play"
 * launch action instead of firing a key at nothing.
 */
class NowPlayingTileService : TileService() {

    private fun playing(): Boolean =
        getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)
            .getBoolean("isPlaying", false) && WidgetActionActivity.isEngineAlive()

    private fun refresh() {
        val tile = qsTile ?: return
        val title = try {
            getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE).getString("title", null)
        } catch (_: Exception) { null }
        val isPlaying = playing()
        tile.label = if (isPlaying && !title.isNullOrEmpty()) title else getString(R.string.qs_tile_label)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = if (!title.isNullOrEmpty()) title else null
        }
        tile.state = if (isPlaying) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.updateTile()
    }

    override fun onStartListening() = refresh()

    override fun onClick() {
        try {
            if (WidgetActionActivity.isEngineAlive()) {
                val key = if (playing()) KeyEvent.KEYCODE_MEDIA_PAUSE else KeyEvent.KEYCODE_MEDIA_PLAY
                WidgetActionActivity.sendMediaButton(applicationContext, key)
                // Optimistic flip; the real state arrives next time it is shown.
                qsTile?.let { it.state = if (key == KeyEvent.KEYCODE_MEDIA_PLAY) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE; it.updateTile() }
            } else {
                val launch = Intent(this, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    putExtra(WidgetActionActivity.EXTRA_ACTION, "play")
                }
                if (Build.VERSION.SDK_INT >= 34) {
                    startActivityAndCollapse(PendingIntent.getActivity(
                        this, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
                } else {
                    @Suppress("DEPRECATION") startActivityAndCollapse(launch)
                }
            }
        } catch (_: Exception) {
            // Never crash from a tile tap.
        }
    }
}
