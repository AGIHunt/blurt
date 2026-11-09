package dev.blurt.remote.app

import android.annotation.SuppressLint
import android.app.Application
import android.content.Context
import dev.blurt.remote.app.keys.Sticky
import dev.blurt.remote.app.net.KeyVault
import dev.blurt.remote.app.net.Link
import dev.blurt.remote.app.net.NetWatch
import dev.blurt.remote.app.pad.ScreenStream
import dev.blurt.remote.app.talk.MicStream

/** The few things there's one of, as on the iPhone (`.shared`). Made once, when the app starts. */
@SuppressLint("StaticFieldLeak")    // the application context only
object Remote {
    lateinit var context: Context
        private set
    lateinit var prefs: Prefs
        private set
    lateinit var vault: KeyVault
        private set
    lateinit var link: Link
        private set
    lateinit var sticky: Sticky
        private set
    lateinit var screen: ScreenStream
        private set
    lateinit var mic: MicStream
        private set
    lateinit var net: NetWatch
        private set

    fun start(c: Context) {
        if (::context.isInitialized) return
        context = c
        prefs = Prefs(c)
        vault = KeyVault(c)
        sticky = Sticky()
        mic = MicStream(c)
        screen = ScreenStream(c)
        link = Link(c, vault)
        net = NetWatch(c) { _, _ -> screen.planChanged() }
        net.start()
        Haptics.on = prefs.haptics
    }
}

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        Remote.start(this)
    }
}
