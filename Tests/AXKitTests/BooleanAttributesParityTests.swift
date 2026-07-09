import ApplicationServices
import AppKit
import XCTest
@testable import AXKit

/// `booleanAttributes` reads every boolean-typed attribute in ONE bulk AX call instead of one call
/// per attribute name. It feeds the `{states}` the control_app tree renders, so a divergence from
/// the per-attribute reads it replaced would silently change every rendered node. These tests pin
/// the two against each other on a live tree.
final class BooleanAttributesParityTests: XCTestCase {
    /// The per-attribute implementation this bulk read replaced, kept here as the oracle.
    private func perAttributeBooleans(_ element: AXElement) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for name in element.attributeNames {
            guard let value = element.copyAttribute(name), CFGetTypeID(value) == CFBooleanGetTypeID() else { continue }
            result[name] = CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
        }
        return result
    }

    private func finderApp() throws -> AXElement {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs Accessibility grant in this environment")
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            throw XCTSkip("Finder not running")
        }
        let app = AXElement.application(pid: finder.processIdentifier)
        app.setMessagingTimeout(2)
        return app
    }

    func testBulkMatchesPerAttributeAcrossALiveTree() throws {
        let app = try finderApp()

        // Breadth-first over a bounded slice of the real tree: enough nodes to hit varied roles
        // (app, menu bar, menus, items) without turning this into a long walk.
        var queue: [AXElement] = [app]
        var index = 0
        var compared = 0
        while index < queue.count, compared < 80 {
            let element = queue[index]
            index += 1
            compared += 1
            XCTAssertEqual(element.booleanAttributes, perAttributeBooleans(element),
                           "bulk and per-attribute boolean reads diverged on a live element")
            if queue.count < 200 { queue.append(contentsOf: element.children) }
        }
        XCTAssertGreaterThan(compared, 1, "expected to walk more than the root")
    }

    /// An element with no attribute names at all must yield an empty map, not trip the bulk call.
    func testEmptyAttributeNamesYieldsEmptyMap() {
        // A destroyed/invalid element reports no attribute names.
        let dead = AXElement.application(pid: 999_999)
        XCTAssertTrue(dead.attributeNames.isEmpty)
        XCTAssertTrue(dead.booleanAttributes.isEmpty)
    }
}
