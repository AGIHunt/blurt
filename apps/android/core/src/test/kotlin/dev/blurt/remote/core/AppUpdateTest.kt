package dev.blurt.remote.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AppUpdateTest {
    @Test fun theTagAtTheEndOfTheRedirect() {
        assertEquals("1.1.1", AppUpdate.version("https://github.com/AGIHunt/blurt/releases/tag/v1.1.1"))
        assertEquals("1.0.26", AppUpdate.version("https://github.com/AGIHunt/blurt/releases/tag/v1.0.26"))
        for (other in listOf(null, "", "https://github.com/login", "https://github.com/AGIHunt/blurt/releases", "https://github.com/AGIHunt/blurt/releases/tag/v1.0.13-alpha.1",
            "https://github.com/someone/blurt/releases/tag/v9.9.9", "https://github.com/AGIHunt/blurt/releases/tag/v1.1.1/../../x")) assertNull(AppUpdate.version(other), other)
    }

    @Test fun versionsCompareNumberByNumber() {
        assertTrue(AppUpdate.newer("1.0.10", "1.0.9"))
        assertTrue(AppUpdate.newer("1.2", "1.1.9"))
        assertTrue(AppUpdate.newer("2.0.0", "1.9.9"))
        assertFalse(AppUpdate.newer("1.1.1", "1.1.1"))
        assertFalse(AppUpdate.newer("1.1", "1.1.0"))
        assertFalse(AppUpdate.newer("1.0.9", "1.0.10"))
        assertFalse(AppUpdate.newer("1.1.1", "1.1.1-dev"))
        assertFalse(AppUpdate.newer("x", "1.1.1"))
        assertFalse(AppUpdate.newer("1.1.2", "x"))
    }

    @Test fun theApkIsTheReleasesOwn() {
        assertEquals("https://github.com/AGIHunt/blurt/releases/download/v1.1.1/Blurt-1.1.1-android.apk", AppUpdate.apk("1.1.1"))
    }

    @Test fun onlyGitHubsHosts() {
        for (h in listOf("github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com")) assertTrue(AppUpdate.trusted(h), h)
        for (h in listOf("blurt.work", "github.com.evil.example", "evilgithubusercontent.com", "api.github.com")) assertFalse(AppUpdate.trusted(h), h)
    }
}
