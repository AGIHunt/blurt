import UIKit

enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let select = UISelectionFeedbackGenerator()
    static var on: Bool { Prefs.shared.haptics }

    static func prepare() { light.prepare(); rigid.prepare(); medium.prepare(); select.prepare() }
    /// a key fired, a click
    static func tick() { if on { rigid.impactOccurred(intensity: 0.7); rigid.prepare() } }
    /// a step of a cycle, an arrow
    static func step() { if on { select.selectionChanged(); select.prepare() } }
    /// took hold of something: a drag, a latch
    static func grab() { if on { medium.impactOccurred(); medium.prepare() } }
    static func release() { if on { light.impactOccurred(); light.prepare() } }
}
