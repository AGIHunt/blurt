import XCTest
@testable import BlurtRemoteKit

final class RemoteHostKeysTests: XCTestCase {
    func testMacLabelsAreTheGlyphsAsBefore() {
        for c in [RemoteChord(.command, "C"), RemoteChord([.command, .shift], "Z"), RemoteChord([.control, .shift], "Tab"), RemoteChord(.command, "Space"),
                  RemoteChord([], "Return"), RemoteChord(.command, "")] {
            XCTAssertEqual(RemoteHost.mac.label(c), c.label)
        }
        XCTAssertEqual(RemoteHost.mac.label(RemoteChord([.command, .shift], "Z")), "⇧⌘Z")
        XCTAssertEqual(RemoteHost.mac.modifierOrder.map { RemoteHost.mac.name($0) }, ["⌃", "⌥", "⇧", "⌘"])
    }

    func testWindowsAndLinuxWriteTheirOwnNames() {
        XCTAssertEqual(RemoteHost.windows.label(RemoteChord(.control, "C")), "Ctrl+C")
        XCTAssertEqual(RemoteHost.windows.label(RemoteChord([.control, .shift], "Escape")), "Ctrl+Shift+Esc")
        XCTAssertEqual(RemoteHost.windows.label(RemoteChord([.command, .shift], "S")), "Win+Shift+S")
        XCTAssertEqual(RemoteHost.windows.label(RemoteChord(.option, "F4")), "Alt+F4")
        XCTAssertEqual(RemoteHost.windows.label(RemoteChord(.command, "")), "Win")
        XCTAssertEqual(RemoteHost.linux.label(RemoteChord(.command, "")), "Super")
        XCTAssertEqual(RemoteHost.linux.label(RemoteChord([.control, .shift], "Z")), "Ctrl+Shift+Z")
        XCTAssertEqual(RemoteHost.linux.label(RemoteChord([.command, .control, .option, .shift], "T")), "Ctrl+Super+Alt+Shift+T")
        XCTAssertEqual(RemoteHost.windows.label(RemoteChord([], "Return")), "Enter")
        XCTAssertEqual(RemoteHost.windows.label(RemoteChord(.control, "Delete")), "Ctrl+Backspace")
        XCTAssertEqual(RemoteHost.linux.label(RemoteChord(.option, "Left")), "Alt+←")
        XCTAssertEqual(RemoteHost.linux.label(RemoteChord(.control, "PageDown")), "Ctrl+PgDn")
        XCTAssertEqual(RemoteHost.windows.modifierOrder.map { RemoteHost.windows.name($0) }, ["Ctrl", "Win", "Alt", "Shift"])
        XCTAssertEqual(RemoteHost.linux.modifierOrder.map { RemoteHost.linux.name($0) }, ["Ctrl", "Super", "Alt", "Shift"])
    }

    func testEveryHostNamesEveryModifier() {
        for h in RemoteHost.allCases {
            XCTAssertEqual(Set(h.modifierOrder.map(\.rawValue)), [1, 2, 4, 8])
            for m in h.modifierOrder { XCTAssertFalse(h.name(m).isEmpty) }
        }
    }

    func testParameterSetsSayTheirCodec() {
        // the first bytes of real ones: an HEVC VPS, an H.264 SPS (both profiles x264 and VideoToolbox write)
        XCTAssertEqual(RemoteVideoCodec.of(parameterSets: [Data([0x40, 0x01, 0x0C]), Data([0x42, 0x01]), Data([0x44, 0x01])]), "hevc")
        XCTAssertEqual(RemoteVideoCodec.of(parameterSets: [Data([0x67, 0x64, 0x00, 0x1F]), Data([0x68, 0xEB])]), "h264")
        XCTAssertEqual(RemoteVideoCodec.of(parameterSets: [Data([0x27, 0x42]), Data([0x28])]), "h264")
        XCTAssertNil(RemoteVideoCodec.of(parameterSets: []))
        XCTAssertNil(RemoteVideoCodec.of(parameterSets: [Data([0x65])]))
    }
}
