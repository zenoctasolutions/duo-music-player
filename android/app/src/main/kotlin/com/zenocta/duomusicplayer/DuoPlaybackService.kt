package com.zenocta.duomusicplayer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps the process in the foreground while a Duo Mode session is active so
 * both ear players keep playing with the screen off / app in the background
 * (a cached, backgrounded process gets frozen on Android 11+). The players
 * themselves live in [DuoEngine]; this only owns the notification, whose
 * buttons control each ear independently plus stop the session.
 */
class DuoPlaybackService : Service() {

    companion object {
        private const val CHANNEL_ID = "zen_duo_mode"
        private const val NOTIFICATION_ID = 7342
        private const val ACTION_TOGGLE_LEFT = "zen.duo.TOGGLE_LEFT"
        private const val ACTION_TOGGLE_RIGHT = "zen.duo.TOGGLE_RIGHT"
        private const val ACTION_STOP = "zen.duo.STOP"

        private var instance: DuoPlaybackService? = null

        fun refresh() {
            instance?.postNotification()
        }

        fun stop() {
            instance?.let {
                it.stopForegroundCompat()
                it.stopSelf()
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        DuoEngine.init(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Duo Mode", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Controls for two-song Duo Mode playback"
                    setShowBadge(false)
                }
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // startForeground must be called promptly after startForegroundService.
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        when (intent?.action) {
            ACTION_TOGGLE_LEFT -> DuoEngine.toggleSide(DuoEngine.LEFT)
            ACTION_TOGGLE_RIGHT -> DuoEngine.toggleSide(DuoEngine.RIGHT)
            ACTION_STOP -> {
                DuoEngine.stopAll()
                return START_NOT_STICKY
            }
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiping the app away ends the Duo session rather than leaving an
        // orphaned notification behind.
        DuoEngine.stopAll()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun postNotification() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification())
    }

    private fun servicePending(action: String, requestCode: Int): PendingIntent =
        PendingIntent.getService(
            this, requestCode,
            Intent(this, DuoPlaybackService::class.java).setAction(action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    private fun buildNotification(): Notification {
        val left = DuoEngine.titleFor(DuoEngine.LEFT) ?: "—"
        val right = DuoEngine.titleFor(DuoEngine.RIGHT) ?: "—"
        val leftPlaying = DuoEngine.isSidePlaying(DuoEngine.LEFT)
        val rightPlaying = DuoEngine.isSidePlaying(DuoEngine.RIGHT)

        val openApp = PendingIntent.getActivity(
            this, 0,
            packageManager.getLaunchIntentForPackage(packageName)
                ?.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        @Suppress("DEPRECATION")
        return builder
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("Duo Mode")
            .setContentText("L: $left  •  R: $right")
            .setStyle(Notification.BigTextStyle().bigText("Left ear: $left\nRight ear: $right"))
            .setContentIntent(openApp)
            .setOngoing(DuoEngine.isAnyPlaying())
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .addAction(
                if (leftPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                if (leftPlaying) "Pause Left" else "Play Left",
                servicePending(ACTION_TOGGLE_LEFT, 1)
            )
            .addAction(
                if (rightPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                if (rightPlaying) "Pause Right" else "Play Right",
                servicePending(ACTION_TOGGLE_RIGHT, 2)
            )
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", servicePending(ACTION_STOP, 3))
            .build()
    }
}
