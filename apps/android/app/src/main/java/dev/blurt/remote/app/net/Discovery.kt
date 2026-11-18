// Finding computers on this network by DNS-SD (`_blurt-remote._tcp`, TXT id=<computer id>), through the system's NsdManager: no multicast
// lock, no library. Android 14+ resolves with the service-info callback, which can watch several at once and hands over every address; older
// versions resolve one service at a time, so those wait their turn.
package dev.blurt.remote.app.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.net.InetAddress
import java.util.concurrent.Executor

class Discovery(c: Context) {
    data class Found(val id: String, val name: String, val addresses: List<InetAddress>, val port: Int)

    private val nsd = c.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val main = Handler(Looper.getMainLooper())
    private val mainExec = Executor { main.post(it) }

    inner class Browse(private val onFound: (Found) -> Unit, private val onLost: (String) -> Unit = {}) {
        private var stopped = false
        private val callbacks = mutableListOf<Any>()
        private val waiting = ArrayDeque<NsdServiceInfo>()
        private var resolving = false
        private val names = mutableMapOf<String, String>()

        private val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) { main.post { resolve(info) } }
            override fun onServiceLost(info: NsdServiceInfo) { main.post { names.remove(info.serviceName)?.let(onLost) } }
        }

        fun start(): Browse {
            runCatching { nsd.discoverServices(TYPE, NsdManager.PROTOCOL_DNS_SD, listener) }
            return this
        }

        private fun resolve(info: NsdServiceInfo) {
            if (stopped) return
            if (Build.VERSION.SDK_INT >= 34) {
                val cb = object : NsdManager.ServiceInfoCallback {
                    override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {}
                    override fun onServiceUpdated(s: NsdServiceInfo) { found(s, s.hostAddresses) }
                    override fun onServiceLost() {}
                    override fun onServiceInfoCallbackUnregistered() {}
                }
                runCatching { nsd.registerServiceInfoCallback(info, mainExec, cb); callbacks += cb }
            } else {
                waiting.addLast(info)
                next()
            }
        }

        @Suppress("DEPRECATION")
        private fun next() {
            if (resolving || stopped) return
            val info = waiting.removeFirstOrNull() ?: return
            resolving = true
            runCatching {
                nsd.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(s: NsdServiceInfo, errorCode: Int) { main.post { resolving = false; next() } }
                    override fun onServiceResolved(s: NsdServiceInfo) {
                        main.post {
                            resolving = false
                            found(s, listOfNotNull(s.host))
                            next()
                        }
                    }
                })
            }.onFailure { resolving = false }
        }

        private fun found(s: NsdServiceInfo, addresses: List<InetAddress>) {
            if (stopped || addresses.isEmpty()) return
            val id = s.attributes["id"]?.let { String(it) } ?: return
            names[s.serviceName] = id
            onFound(Found(id, s.serviceName, addresses, s.port))
        }

        fun stop() {
            if (stopped) return
            stopped = true
            runCatching { nsd.stopServiceDiscovery(listener) }
            if (Build.VERSION.SDK_INT >= 34) for (cb in callbacks) runCatching { nsd.unregisterServiceInfoCallback(cb as NsdManager.ServiceInfoCallback) }
            callbacks.clear()
            waiting.clear()
        }
    }

    fun browse(onFound: (Found) -> Unit, onLost: (String) -> Unit = {}): Browse = Browse(onFound, onLost).start()

    companion object {
        /** NsdManager wants the type without the trailing dot, as RemotePairing.SERVICE_TYPE is */
        const val TYPE = "_blurt-remote._tcp"
    }
}
