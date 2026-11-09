// What the phone is on, for how much picture to ask for (ScreenPlan): mobile data or a metered network (a phone's hotspot is Wi-Fi the user
// pays for), and Data Saver, Android's Low Data Mode.
package dev.blurt.remote.app.net

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat

class NetWatch(private val c: Context, private val changed: (cellular: Boolean, lowData: Boolean) -> Unit) {
    private val cm = c.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val main = Handler(Looper.getMainLooper())
    var cellular = false
        private set
    var lowData = false
        private set

    private fun saver() = cm.restrictBackgroundStatus == ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED

    private fun update(caps: NetworkCapabilities?) {
        val mobile = caps != null && (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
            !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED))
        val low = saver()
        main.post {
            if (mobile == cellular && low == lowData) return@post
            cellular = mobile
            lowData = low
            changed(mobile, low)
        }
    }

    fun start() {
        runCatching {
            cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = update(caps)
                override fun onLost(network: Network) = update(null)
            })
        }
        ContextCompat.registerReceiver(c, object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) = update(cm.getNetworkCapabilities(cm.activeNetwork))
        }, IntentFilter(ConnectivityManager.ACTION_RESTRICT_BACKGROUND_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED)
        update(cm.getNetworkCapabilities(cm.activeNetwork))
    }
}
