// BlurtCore/MicChannelMap.swift: a 4-channel interface's take heard silence — the converter's own map was all -1.
import XCTest
@testable import BlurtCore

final class MicChannelMapTests: XCTestCase {
    func testAFourChannelInterfaceTakesItsFirstChannels() {
        XCTAssertEqual(MicChannelMap.silenceFix(device: 4, kept: 1, map: [-1]), [0])
        XCTAssertEqual(MicChannelMap.silenceFix(device: 4, kept: 2, map: [-1, -1]), [0, 1])
    }

    func testAMapThatAlreadyCarriesSoundIsLeftAlone() {
        XCTAssertNil(MicChannelMap.silenceFix(device: 2, kept: 1, map: [0]))
        XCTAssertNil(MicChannelMap.silenceFix(device: 4, kept: 2, map: [0, 1]))
    }

    func testNoDropOrNoChannelsIsLeftAlone() {
        XCTAssertNil(MicChannelMap.silenceFix(device: 1, kept: 1, map: [0]))
        XCTAssertNil(MicChannelMap.silenceFix(device: 2, kept: 1, map: [0]))
        XCTAssertNil(MicChannelMap.silenceFix(device: 4, kept: 0, map: []))
    }

    func testAMapOfTheWrongLengthIsLeftAlone() {
        XCTAssertNil(MicChannelMap.silenceFix(device: 4, kept: 1, map: [-1, -1]))
    }
}
