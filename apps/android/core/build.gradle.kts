// Blurt Remote's protocol and the phone's logic as plain Kotlin/JVM, with no Android dependency: the wire, the seals, the pad, the deck.
// The Android app includes this build (includeBuild("core")) and depends on "dev.blurt.remote:core". API: docs/design/remote-android.md.
plugins {
    kotlin("jvm") version "2.2.20"
    kotlin("plugin.serialization") version "2.2.20"
    `java-library`
}

group = "dev.blurt.remote"
version = "1.0"

kotlin {
    jvmToolchain(17)
}

dependencies {
    // JsonElement-level codecs: the Swift Codable shape is written by hand, so no serialization plugin types leak into the API
    api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    // X25519, HKDF, ChaCha20-Poly1305, HMAC, SHA-256: the same on every Android version from API 26
    implementation("org.bouncycastle:bcprov-jdk18on:1.82")
    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.13.4")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test {
    useJUnitPlatform()
    // the golden vectors live at the repo root
    systemProperty("blurt.vectors", rootDir.resolve("../../../tests/remote-vectors/vectors.json").canonicalPath)
    testLogging {
        events("failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}
