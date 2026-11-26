// Ways in for a test run against local copies of Blurt's servers, debug builds only (as TestWeather): a release reads none of this, and
// goes only to wss://meet.blurt.work and wss://relay.blurt.work. Set by extras on the launch intent:
//
//   adb shell am start -n dev.blurt.remote/.app.MainActivity --es blurt_go_between ws://10.0.2.2:8801 \
//       --es blurt_public_relay ws://10.0.2.2:8802 --ez blurt_no_direct true --ez blurt_relay_only true
//
//   blurt_go_between    this address counts as Blurt's go-between (tools/remote-relay/server.js with BUDGET=1)
//   blurt_public_relay  a public relay at this address is allowed besides Blurt's own (tools/remote-relay/public.js)
//   blurt_no_direct     no direct UDP path is looked for over a relay, as on a network where it won't open
//   blurt_relay_only    no local or overlay addresses are tried: only the relay the computer named (or the go-between above)
package dev.blurt.remote.app.net

import android.content.Intent
import dev.blurt.remote.app.BuildConfig
import dev.blurt.remote.core.RemoteRelay

object TestRoutes {
    @Volatile var goBetween: String? = null
        private set
    @Volatile var publicRelay: String? = null
        private set
    @Volatile var noDirect = false
        private set
    @Volatile var relayOnly = false
        private set

    fun from(i: Intent?) {
        if (!BuildConfig.DEBUG || i == null) return
        i.getStringExtra("blurt_go_between")?.let { goBetween = RemoteRelay.address(it) }
        i.getStringExtra("blurt_public_relay")?.let { publicRelay = RemoteRelay.address(it) }
        if (i.hasExtra("blurt_no_direct")) noDirect = i.getBooleanExtra("blurt_no_direct", false)
        if (i.hasExtra("blurt_relay_only")) relayOnly = i.getBooleanExtra("blurt_relay_only", false)
    }
}
