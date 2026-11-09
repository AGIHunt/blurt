// Blurt for Android: the phone (or tablet, or foldable) as trackpad, keys, microphone and screen for Blurt on the computer.
// `core` is the protocol and the phone's logic as plain Kotlin/JVM (its own build, tested on its own); `app` is everything Android.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "blurt-android"

includeBuild("core")
include(":app")
// a fake computer for trying the app without Blurt (fakehost/build.gradle.kts)
include(":fakehost")
