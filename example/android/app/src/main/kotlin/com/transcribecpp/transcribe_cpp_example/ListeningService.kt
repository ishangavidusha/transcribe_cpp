package com.transcribecpp.transcribe_cpp_example

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
import android.util.Log

/**
 * Keeps the microphone live while the app is in the background.
 *
 * Android silences an app's recording a few seconds after it leaves the
 * foreground unless the app is running a foreground service of type
 * `microphone`. The service does no work of its own: transcribe_cpp goes on
 * capturing exactly as before, and the service is what tells the system, and
 * the user through its notification, that the app is still listening.
 *
 * Start it after `TranscribeSession.start()` and stop it after `stop()`.
 * From Android 14 a microphone service can only start while the app is in
 * the foreground and holds RECORD_AUDIO, which is exactly the state right
 * after a session starts.
 */
class ListeningService : Service() {

    companion object {
        private const val CHANNEL = "listening"
        private const val NOTIFICATION_ID = 1

        fun start(context: Context) {
            val intent = Intent(context, ListeningService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ListeningService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification())
            }
        } catch (e: RuntimeException) {
            // Started from the background, or without RECORD_AUDIO. Listening
            // still works in the foreground; it just will not survive leaving.
            Log.w("ListeningService", "Could not keep listening in the background", e)
            stopSelf()
        }
        // Not restarted after the process dies: the session died with it.
        return START_NOT_STICKY
    }

    private fun notification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Listening", NotificationManager.IMPORTANCE_LOW),
            )
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE)
        }
        return builder
            .setContentTitle("Listening")
            .setContentText("Transcribing on this device")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setContentIntent(open)
            .build()
    }
}
