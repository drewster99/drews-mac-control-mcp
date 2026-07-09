import ApplicationServices
import AppKit
import XCTest
@testable import AXKit

/// `ControlWalker.draft` now takes every field it can from one bulk `snapshotAttributes()` call
/// instead of ~15 separate cross-process reads. `draft`'s own logic is unchanged, so the rendered
/// tree is unchanged **iff** the bulk-decoded fields equal the per-attribute accessor values they
/// replaced. These tests assert exactly that, field by field, against live AX trees — which is a
/// sharper check than diffing rendered text, since it doesn't depend on the UI holding still.
final class SnapshotAttributesParityTests: XCTestCase {
    private func liveApps() throws -> [AXElement] {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs Accessibility grant in this environment")
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .prefix(6)
            .map { app -> AXElement in
                let element = AXElement.application(pid: app.processIdentifier)
                element.setMessagingTimeout(2)
                return element
            }
        try XCTSkipUnless(!apps.isEmpty, "no regular apps running")
        return Array(apps)
    }

    /// Every field `draft` reads, compared bulk-vs-accessor on one element.
    private func assertParity(_ element: AXElement, file: StaticString = #filePath, line: UInt = #line) {
        let attributes = element.snapshotAttributes()

        XCTAssertEqual(attributes.role, element.role, "role", file: file, line: line)
        XCTAssertEqual(attributes.subrole, element.subrole, "subrole", file: file, line: line)
        XCTAssertEqual(attributes.identifier, element.identifier, "identifier", file: file, line: line)
        XCTAssertEqual(attributes.title, element.title, "title", file: file, line: line)
        XCTAssertEqual(attributes.axDescription, element.axDescription, "axDescription", file: file, line: line)
        XCTAssertEqual(attributes.help, element.help, "help", file: file, line: line)
        XCTAssertEqual(attributes.valueDescription, element.valueDescription, "valueDescription", file: file, line: line)
        XCTAssertEqual(attributes.placeholder, element.placeholderValue, "placeholder", file: file, line: line)
        XCTAssertEqual(attributes.url, element.url, "url", file: file, line: line)

        // The numeric-vs-text distinction is what the renderer keys on (=0.72 bare vs ="007" quoted),
        // so both readings of slot 4 must agree with their accessors independently.
        XCTAssertEqual(attributes.value, element.value, "value", file: file, line: line)
        XCTAssertEqual(attributes.numericValue, element.numericValue, "numericValue", file: file, line: line)

        XCTAssertEqual(attributes.minValue, element.minValue, "minValue", file: file, line: line)
        XCTAssertEqual(attributes.maxValue, element.maxValue, "maxValue", file: file, line: line)
        XCTAssertEqual(attributes.disclosureLevel, element.disclosureLevel, "disclosureLevel", file: file, line: line)
        XCTAssertEqual(attributes.isDisclosing, element.isDisclosing, "isDisclosing", file: file, line: line)
        XCTAssertEqual(attributes.rowCount, element.rowCount, "rowCount", file: file, line: line)
        XCTAssertEqual(attributes.columnCount, element.columnCount, "columnCount", file: file, line: line)
        XCTAssertEqual(attributes.columnTitles, element.columnTitles, "columnTitles", file: file, line: line)

        // Children must be the same elements in the same order: the walk's `visited` set dedups by
        // CFEqual, and childrenToWalk now hands these to the expansion step directly.
        XCTAssertEqual(attributes.children, element.children, "children", file: file, line: line)
    }

    /// Breadth-first over several live apps' menu bars and windows — enough breadth to hit menus,
    /// menu items, buttons, static text, and (in most apps) at least one collection.
    func testBulkDecodeMatchesPerAttributeAccessorsAcrossLiveTrees() throws {
        var queue = try liveApps()
        var index = 0
        var visited = Set<AXElement>(queue)
        var compared = 0

        while index < queue.count, compared < 400 {
            let element = queue[index]
            index += 1
            compared += 1
            assertParity(element)
            if queue.count < 600 {
                for child in element.children where visited.insert(child).inserted {
                    queue.append(child)
                }
            }
        }
        XCTAssertGreaterThan(compared, 20, "expected to compare a meaningful slice of the tree")
    }

    /// A dead element's bulk read fails outright, exercising the per-attribute fallback branch —
    /// which must populate the new fields too, or bulk-hostile apps would silently render differently.
    func testFallbackBranchYieldsTheSameAbsentFields() {
        let dead = AXElement.application(pid: 999_999)
        let attributes = dead.snapshotAttributes()
        XCTAssertNil(attributes.role)
        XCTAssertNil(attributes.numericValue)
        XCTAssertNil(attributes.minValue)
        XCTAssertNil(attributes.maxValue)
        XCTAssertNil(attributes.disclosureLevel)
        XCTAssertNil(attributes.isDisclosing)
        XCTAssertNil(attributes.rowCount)
        XCTAssertNil(attributes.columnCount)
        XCTAssertNil(attributes.columnTitles)
        XCTAssertTrue(attributes.children.isEmpty)
    }
}
