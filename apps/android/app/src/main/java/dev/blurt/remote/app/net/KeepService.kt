// A session kept while the app is out of sight (Link.background). Android's freezer stops an app about 6 s after it leaves the screen, and
// Android 15 closes its sockets with it (measured on the emulator), so for the three minutes a session is kept a foreground service says the
// process is in use: `connectedDevice`, which is what the computer is. The notification says so, quietly, with Disconnect; with
// notifications off it runs all the same, and nothing asks for them.
//
// Started with startService, not startForegroundService: the app has just left the screen, when both are allowed, and a service stopped
// before it got going then costs nothing (startForegroundService ends the process for that). Where Android won't let it run, Link keeps the
// session only as long as the process may hang on.
package dev.blurt.remote.app.net

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import dev.blurt.remote.app.MainActivity
import dev.blurt.remote.app.R
import dev.blurt.remote.app.Remote
import dev.blurt.remote.core.Reconnect

class KeepService : Service() {
    private var awake: PowerManager.WakeLock? = null

    override fun onBind(i: Intent?): IBinder? = null

    override fun onStartCommand(i: Intent?, flags: Int, startId: Int): Int {
        if (i?.action == DISCONNECT) {
            Remote.link.keepEnded()
            stopSelf()
            return START_NOT_STICKY
        }
        // back in the app before this got going
        if (!wanted) {
            stopSelf()
            return START_NOT_STICKY
        }
        running = this
        try {
            val type = if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0
            ServiceCompat.startForeground(this, ID, notification(i?.getStringExtra(NAME) ?: ""), type)
            // the screen goes off and the processor with it, and a computer that hears nothing for 12 s takes the phone as gone
            awake = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "blurt:keep").apply {
                setReferenceCounted(false)
                acquire(Reconnect.keepInBackgroundMs(true) + 5_000)
            }
        } catch (e: RuntimeException) {
            // ForegroundServiceStartNotAllowedException (an IllegalStateException), SecurityException
            Log.i("Link", "no foreground service: $e")
            stopSelf()
            Remote.link.keepFailed()
        }
        return START_NOT_STICKY
    }

    private fun notification(name: String): android.app.Notification {
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, getString(R.string.keep_channel), NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE)
        val end = PendingIntent.getService(this, 1, Intent(this, KeepService::class.java).setAction(DISCONNECT), PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_connected)
            .setContentTitle(getString(R.string.still_connected, name.ifEmpty { getString(R.string.the_computer) }))
            .setContentIntent(open)
            .addAction(0, getString(R.string.disconnect), end)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    /** The app was swiped away: so is the session. */
    override fun onTaskRemoved(i: Intent?) {
        Remote.link.keepEnded()
        stopSelf()
    }

    override fun onDestroy() {
        awake?.let { if (it.isHeld) it.release() }
        awake = null
        if (running === this) running = null
    }

    companion object {
        private const val CHANNEL = "connection"
        private const val ID = 1
        private const val NAME = "name"
        private const val DISCONNECT = "dev.blurt.remote.DISCONNECT"
        private var wanted = false
        private var running: KeepService? = null

        /** False: Android won't have it. Main thread, as everything here. */
        fun start(c: Context, name: String): Boolean {
            wanted = true
            return try {
                c.startService(Intent(c, KeepService::class.java).putExtra(NAME, name)) != null
            } catch (e: RuntimeException) {
                // BackgroundServiceStartNotAllowedException (an IllegalStateException), SecurityException
                Log.i("Link", "no service: $e")
                wanted = false
                false
            }
        }

        fun stop() {
            wanted = false
            running?.stopSelf()
        }
    }
}
