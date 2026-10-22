// The notch island (K7, P5): installed after the other modules (AppEnvironment.installModules) in the menu-bar app;
// sets AppEnvironment.island. A recording started from the chat (no menu-bar app) starts the island on its own.
import AppKit
import BlurtCore

enum IslandModule {
    static func install() {
        AppEnvironment.island = island
        island.start()
        snapper.restore()
    }
}
