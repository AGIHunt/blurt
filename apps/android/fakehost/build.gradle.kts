// A fake computer for trying the Android app without Blurt: it pairs, opens sessions with core's MacHandshake, logs every key, click, scroll
// and word of audio that arrives, and can stream a picture (ffmpeg's encoder) so the screen view has something to show. Not part of the app.
//   ./gradlew :fakehost:run --args="--platform mac --name 'Studio Mac' --picture desk.png"
// The emulator reaches this Mac at 10.0.2.2: the pairing link it prints says so.
plugins {
    id("org.jetbrains.kotlin.jvm")
    application
}

kotlin { jvmToolchain(17) }

dependencies {
    implementation("dev.blurt.remote:core")
}

application {
    mainClass.set("dev.blurt.remote.fakehost.FakeHostKt")
}

tasks.named<JavaExec>("run") {
    standardInput = System.`in`
    workingDir = rootDir
}
