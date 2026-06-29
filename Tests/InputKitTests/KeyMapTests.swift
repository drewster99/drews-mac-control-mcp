import XCTest
import CoreGraphics
@testable import InputKit

final class KeyMapTests: XCTestCase {
    func testBareKey() {
        XCTAssertEqual(KeyMap.parse("s"), KeyChord(keyCode: 1, flags: []))
        XCTAssertEqual(KeyMap.parse("return"), KeyChord(keyCode: 36, flags: []))
        XCTAssertEqual(KeyMap.parse("escape"), KeyChord(keyCode: 53, flags: []))
    }

    func testSingleModifier() {
        XCTAssertEqual(KeyMap.parse("cmd+s"), KeyChord(keyCode: 1, flags: .maskCommand))
        XCTAssertEqual(KeyMap.parse("command+s"), KeyChord(keyCode: 1, flags: .maskCommand))
    }

    func testMultipleModifiers() {
        XCTAssertEqual(KeyMap.parse("cmd+shift+z"), KeyChord(keyCode: 6, flags: [.maskCommand, .maskShift]))
        XCTAssertEqual(KeyMap.parse("ctrl+opt+delete"), KeyChord(keyCode: 51, flags: [.maskControl, .maskAlternate]))
    }

    func testCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(KeyMap.parse("CMD + S"), KeyChord(keyCode: 1, flags: .maskCommand))
    }

    func testUnknownKeyReturnsNil() {
        XCTAssertNil(KeyMap.parse("cmd+nope"))
        XCTAssertNil(KeyMap.parse("nope"))
    }

    func testUnknownModifierReturnsNil() {
        XCTAssertNil(KeyMap.parse("hyper+s"))
    }

    func testPlusKeyViaTrailingPlus() {
        // "cmd++" targets the literal plus key (the "=" keycode) — the trailing "+" must not be
        // dropped by the separator split.
        XCTAssertEqual(KeyMap.parse("cmd++"), KeyChord(keyCode: 24, flags: .maskCommand))
        XCTAssertEqual(KeyMap.parse("+"), KeyChord(keyCode: 24, flags: []))
    }

    func testPlusAndMinusAliases() {
        XCTAssertEqual(KeyMap.parse("cmd+plus"), KeyChord(keyCode: 24, flags: .maskCommand))
        XCTAssertEqual(KeyMap.parse("equal"), KeyChord(keyCode: 24, flags: []))
        XCTAssertEqual(KeyMap.parse("cmd+minus"), KeyChord(keyCode: 27, flags: .maskCommand))
    }

    func testExistingShiftEqualStillParses() {
        XCTAssertEqual(KeyMap.parse("cmd+shift+="), KeyChord(keyCode: 24, flags: [.maskCommand, .maskShift]))
    }
}
