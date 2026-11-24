// A newer version, from GitHub's releases (docs/design/remote-android.md §Updates): the app is installed as an APK, so no store looks for one.
// Looks once a day while the app is in front, quietly; downloads and installs only when asked. The APK comes from the release itself and is
// installed by Android, which refuses one that isn't signed with the key this one is.
package dev.blurt.remote.app

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.IntentCompat
import androidx.core.content.pm.PackageInfoCompat
import dev.blurt.remote.core.AppUpdate
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request

class Updates(private val c: Context, private val prefs: Prefs) {
    sealed class State {
        data object Idle : State()
        data object Checking : State()
        data object Current : State()
        data object CheckFailed : State()
        data class Available(val version: String) : State()
        data class Downloading(val version: String, val percent: Int) : State()
        data class DownloadFailed(val version: String) : State()
        /** downloaded: Android is asking, or said no */
        data class Ready(val version: String) : State()
        data class InstallFailed(val version: String) : State()

        /** there's a newer version, whatever has become of it */
        val newer: String? get() = when (this) {
            is Available -> version
            is Downloading -> version
            is DownloadFailed -> version
            is Ready -> version
            is InstallFailed -> version
            else -> null
        }
    }

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state
    private val scope: CoroutineScope = MainScope()
    private var job: Job? = null
    private val http by lazy {
        OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS)
            .followRedirects(false).followSslRedirects(false).build()
    }
    private val dir get() = File(c.cacheDir, "update")

    /** Installed by a store: that's what updates it. */
    val offered: Boolean by lazy {
        val by = runCatching {
            if (Build.VERSION.SDK_INT >= 30) c.packageManager.getInstallSourceInfo(c.packageName).installingPackageName
            else @Suppress("DEPRECATION") c.packageManager.getInstallerPackageName(c.packageName)
        }.getOrNull()
        by != "com.android.vending"
    }

    /** In front again: once a day, saying nothing unless there's one. */
    fun auto() {
        if (BuildConfig.DEBUG || !offered || !prefs.autoUpdateCheck || job?.isActive == true || _state.value.newer != null) return
        val since = System.currentTimeMillis() - prefs.updateCheckedAt
        if (since in 0 until DAY) return
        look(quiet = true)
    }

    fun check() {
        if (job?.isActive != true) look(quiet = false)
    }

    private fun look(quiet: Boolean) {
        if (!quiet) _state.value = State.Checking
        job = scope.launch {
            val found = runCatching { withContext(Dispatchers.IO) { newest() } }
            found.onSuccess { v ->
                prefs.updateCheckedAt = System.currentTimeMillis()
                _state.value = if (v != null) State.Available(v) else if (quiet) State.Idle else State.Current
                if (v == null) withContext(Dispatchers.IO) { dir.deleteRecursively() }      // what was downloaded is installed now
            }.onFailure { if (!quiet) _state.value = State.CheckFailed }
        }
    }

    /** The latest release's version, if it's newer and has an APK (a release may be for computers only). */
    private fun newest(): String? {
        val v = http.newCall(Request.Builder().url(AppUpdate.LATEST).head().build()).execute().use { r ->
            if (!r.isRedirect) throw IOException("no redirect: ${r.code}")
            AppUpdate.version(r.header("Location")) ?: throw IOException("no version")
        }
        if (!AppUpdate.newer(v, BuildConfig.VERSION_NAME)) return null
        // the release's own redirect to the file is there only if the file is
        return http.newCall(Request.Builder().url(AppUpdate.apk(v)).head().build()).execute().use { r ->
            if (r.isRedirect || r.isSuccessful) v else if (r.code == 404) null else throw IOException("apk: ${r.code}")
        }
    }

    /** Asked for: download it, or with it here already, install it. */
    fun install() {
        val v = _state.value.newer ?: return
        if (job?.isActive == true) return
        job = scope.launch {
            val file = File(dir, "Blurt-$v.apk")
            if (_state.value !is State.Ready || !file.exists()) {
                _state.value = State.Downloading(v, 0)
                val ok = runCatching { withContext(Dispatchers.IO) { download(AppUpdate.apk(v), file) { p -> _state.value = State.Downloading(v, p) } } }
                if (ok.isFailure) { _state.value = State.DownloadFailed(v); return@launch }
            }
            _state.value = State.Ready(v)
            runCatching { withContext(Dispatchers.IO) { hand(file) } }.onFailure {
                withContext(Dispatchers.IO) { file.delete() }
                _state.value = State.InstallFailed(v)
            }
        }
    }

    private suspend fun download(url: String, to: File, progress: (Int) -> Unit) {
        dir.deleteRecursively()
        dir.mkdirs()
        var at = url
        val part = File(dir, "part")
        repeat(5) {
            val u = okhttp3.HttpUrl.Builder().scheme("https").host("github.com").build().resolve(at) ?: throw IOException("url")
            if (!u.isHttps || !AppUpdate.trusted(u.host)) throw IOException("not GitHub: ${u.host}")
            http.newCall(Request.Builder().url(u).build()).execute().use { r ->
                if (r.isRedirect) { at = r.header("Location") ?: throw IOException("redirect"); return@use }
                if (!r.isSuccessful) throw IOException("${r.code}")
                val total = r.body.contentLength()
                if (total > MOST) throw IOException("too big")
                var read = 0L
                r.body.byteStream().use { i ->
                    part.outputStream().use { o ->
                        val buf = ByteArray(64 * 1024)
                        while (true) {
                            currentCoroutineContextActive()
                            val n = i.read(buf)
                            if (n < 0) break
                            o.write(buf, 0, n)
                            read += n
                            if (read > MOST) throw IOException("too big")
                            if (total > 0) progress((read * 100 / total).toInt())
                        }
                    }
                }
                if (total > 0 && read != total) throw IOException("cut short")
                if (!part.renameTo(to)) throw IOException("rename")
                return
            }
        }
        throw IOException("too many redirects")
    }

    private suspend fun currentCoroutineContextActive() = kotlin.coroutines.coroutineContext.ensureActive()

    /** To Android's installer, which asks the user, and checks the signature against this app's. */
    private fun hand(file: File) {
        val pm = c.packageManager
        val info = pm.getPackageArchiveInfo(file.path, 0) ?: throw IOException("not an APK")
        if (info.packageName != c.packageName) throw IOException("another app")
        if (PackageInfoCompat.getLongVersionCode(info) <= BuildConfig.VERSION_CODE) throw IOException("not newer")
        val installer = pm.packageInstaller
        for (s in installer.mySessions) runCatching { installer.abandonSession(s.sessionId) }       // one that was never answered
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(c.packageName)
            setSize(file.length())
            if (Build.VERSION.SDK_INT >= 26) setInstallReason(PackageManager.INSTALL_REASON_USER)
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { s ->
            s.openWrite("blurt.apk", 0, file.length()).use { o ->
                file.inputStream().use { it.copyTo(o) }
                s.fsync(o)
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            s.commit(PendingIntent.getBroadcast(c, id, Intent(c, UpdateReceiver::class.java), flags).intentSender)
        }
    }

    /** What the installer said. */
    fun answered(i: Intent) {
        val v = _state.value.newer ?: return
        when (i.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val ask = IntentCompat.getParcelableExtra(i, Intent.EXTRA_INTENT, Intent::class.java) ?: return
                runCatching { c.startActivity(ask.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }.onFailure { _state.value = State.InstallFailed(v) }
            }
            PackageInstaller.STATUS_SUCCESS -> {}       // Android is replacing this app
            PackageInstaller.STATUS_FAILURE_ABORTED -> _state.value = State.Ready(v)     // the user said not now
            else -> _state.value = State.InstallFailed(v)
        }
    }

    companion object {
        const val DAY = 24 * 3600_000L
        /** an APK is under 10 MB; anything this big isn't one */
        const val MOST = 100L * 1024 * 1024
    }
}

class UpdateReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) {
        Remote.start(c.applicationContext)
        Remote.updates.answered(i)
    }
}
