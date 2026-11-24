// A newer Blurt for Android, as GitHub's releases say it (docs/design/remote-android.md §Updates). No API call and no feed of our own:
// github.com/AGIHunt/blurt/releases/latest redirects to the latest release's page, whose address ends in its tag, and the APK is
// attached to that release under a name made from the version. Nothing here touches the network; the app does (Updates.kt).
package dev.blurt.remote.core

object AppUpdate {
    const val REPO = "https://github.com/AGIHunt/blurt"
    const val LATEST = "$REPO/releases/latest"

    /** Where GitHub's own files come from: the only hosts the APK may be read from, redirects included. */
    fun trusted(host: String) = host == "github.com" || host.endsWith(".githubusercontent.com")

    /** The version in `…/releases/tag/v1.2.3`; null for anything else (a pre-release's tag, a sign-in page). */
    fun version(location: String?): String? =
        location?.let { Regex("""/AGIHunt/blurt/releases/tag/v(\d+(?:\.\d+){1,3})$""").find(it)?.groupValues?.get(1) }

    fun apk(version: String) = "$REPO/releases/download/v$version/Blurt-$version-android.apk"

    fun page(version: String) = "$REPO/releases/tag/v$version"

    /** `a` is later than `b`, number by number: 1.0.10 after 1.0.9, 1.1 the same as 1.1.0. Not a version: not later. */
    fun newer(a: String, b: String): Boolean {
        val x = numbers(a) ?: return false
        val y = numbers(b) ?: return false
        for (i in 0 until maxOf(x.size, y.size)) {
            val d = x.getOrElse(i) { 0 } - y.getOrElse(i) { 0 }
            if (d != 0) return d > 0
        }
        return false
    }

    /** A test build's "1.1.1-dev" counts as 1.1.1. */
    private fun numbers(v: String): List<Int>? = v.substringBefore('-').split('.').map { it.toIntOrNull() ?: return null }.takeIf { it.isNotEmpty() }
}
