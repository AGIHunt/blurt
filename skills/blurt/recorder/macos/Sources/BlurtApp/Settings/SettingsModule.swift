// WP6 (mac-settings-system) owns Settings/, Onboarding/, System/. Called once at launch by the menu-bar app:
// set AppEnvironment.settings / fixWithAgent / openURL, NSApp.servicesProvider ("Add to Blurt"), Spotlight here.
enum SettingsModule {
    static func install() {}
}
