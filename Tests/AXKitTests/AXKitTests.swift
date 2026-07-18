import XCTest
@testable import AXKit

final class AXKitTests: XCTestCase {
    func testRefAllocatorIsSequential() {
        let allocator = RefAllocator()
        XCTAssertEqual(allocator.next(), "e1")
        XCTAssertEqual(allocator.next(), "e2")
        XCTAssertEqual(allocator.next(), "e3")
    }

    func testAllocatorsAreIndependent() {
        let a = RefAllocator()
        let b = RefAllocator()
        _ = a.next()
        _ = a.next()
        XCTAssertEqual(b.next(), "e1")
    }

    /// Exercises the snapshot builder's run path against a real system-wide element,
    /// assigning refs through the provided closure. Without a grant the attributes read as
    /// nil (role → "AXUnknown"), but the walk must still produce a rooted node.
    func testSnapshotBuildAssignsRefsViaProvider() {
        var counter = 0
        let node = AXSnapshot.build(.systemWide(), maxDepth: 1) { _ in
            counter += 1
            return "e\(counter)"
        }.root
        XCTAssertEqual(node.ref, "e1")
        XCTAssertFalse(node.role.isEmpty)
    }

    func testCleanActionNameReducesCustomActionBlobs() {
        // Standard single-line action tokens pass through untouched.
        XCTAssertEqual(AXElement.cleanActionName("AXPress"), "AXPress")
        // An NSAccessibilityCustomAction description blob collapses to its display name.
        XCTAssertEqual(AXElement.cleanActionName("Name:Move next\nTarget:0x0\nSelector:(null)"), "Move next")
        XCTAssertEqual(AXElement.cleanActionName("Name:Remove from toolbar\nTarget:0x0\nSelector:(null)"),
                       "Remove from toolbar")
        // Any other multi-line content is flattened to one line.
        XCTAssertEqual(AXElement.cleanActionName("foo\nbar"), "foo bar")
        XCTAssertFalse(AXElement.cleanActionName("Name:X\nTarget:0").contains("\n"))
    }
}

/// Deterministic coverage of the find_elements (§8) match predicate, exercised without a
/// live AX tree. Mirrors the real-world case the live e2e surfaced: Calculator labels its
/// digit buttons via AXIdentifier ("Seven"), not AXTitle.
final class FindPredicateTests: XCTestCase {
    private func m(role: String? = nil, subrole: String? = nil, label: String? = nil,
                   identifier: String? = nil, value: String? = nil, valueDescription: String? = nil,
                   placeholder: String? = nil, url: String? = nil, actions: [String] = [],
                   query: String? = nil, roleFilter: String? = nil, titleContains: String? = nil,
                   identifierFilter: String? = nil, valueContains: String? = nil,
                   actionable: Bool? = nil) -> Bool {
        ElementRegistry.elementMatches(
            role: role, subrole: subrole, label: label, identifier: identifier, value: value,
            valueDescription: valueDescription, placeholder: placeholder, url: url, actions: actions,
            query: query, roleFilter: roleFilter, titleContains: titleContains,
            identifierFilter: identifierFilter, valueContains: valueContains, actionable: actionable)
    }

    func testNoFiltersMatchesAnything() {
        XCTAssertTrue(m(role: "AXButton"))
    }

    // The bug that made find_elements "suck": control_app shows `link`, but the old predicate only
    // matched the raw `AXLink`. Now either form (and case) is accepted.
    func testRoleFilterAcceptsHumanizedOrRaw() {
        XCTAssertTrue(m(role: "AXLink", roleFilter: "link"))
        XCTAssertTrue(m(role: "AXLink", roleFilter: "AXLink"))
        XCTAssertTrue(m(role: "AXLink", roleFilter: "LINK"))
        XCTAssertTrue(m(role: "AXWebArea", roleFilter: "webArea"))
        XCTAssertFalse(m(role: "AXLink", roleFilter: "button"))
    }

    // Roles the tree humanizes from the SUBROLE (window, tab) must match that displayed name.
    func testRoleFilterMatchesSubroleAliasedNames() {
        XCTAssertTrue(m(role: "AXWindow", subrole: "AXStandardWindow", roleFilter: "window"))
        XCTAssertTrue(m(role: "AXButton", subrole: "AXTabButton", roleFilter: "tab"))
        XCTAssertTrue(m(role: "AXWindow", subrole: "AXStandardWindow", roleFilter: "AXWindow"))
    }

    func testIdentifierIsExactNotSubstring() {
        XCTAssertTrue(m(identifier: "Seven", identifierFilter: "Seven"))
        XCTAssertFalse(m(identifier: "Eight", identifierFilter: "Seven"))
        XCTAssertFalse(m(identifier: "SevenEighths", identifierFilter: "Seven"))
        XCTAssertFalse(m(identifier: nil, identifierFilter: "Seven"))
    }

    func testTitleAndValueContainsAreCaseInsensitive() {
        // The caller lowercases the needle; the predicate lowercases the haystack.
        XCTAssertTrue(m(label: "Save As…", titleContains: "save"))
        XCTAssertFalse(m(label: "Cancel", titleContains: "save"))
        XCTAssertTrue(m(value: "Total: 78", valueContains: "78"))
        XCTAssertFalse(m(value: "Total: 12", valueContains: "78"))
    }

    func testQueryMatchesAcrossEveryVisibleField() {
        XCTAssertTrue(m(label: "Sign in", query: "sign"))
        XCTAssertTrue(m(value: "Total 78", query: "78"))
        XCTAssertTrue(m(valueDescription: "72 percent", query: "percent"))
        XCTAssertTrue(m(placeholder: "Search jobs", query: "search"))
        XCTAssertTrue(m(url: "https://example.com/apply", query: "apply"))
        XCTAssertTrue(m(identifier: "submit-btn", query: "submit"))
        XCTAssertFalse(m(label: "Cancel", query: "save"))
        XCTAssertTrue(m(label: "Cancel", query: ""))   // empty query is no constraint
    }

    func testActionableOnlyConstrainsWhenTrue() {
        XCTAssertTrue(m(actions: ["AXPress"], actionable: true))
        XCTAssertFalse(m(actions: [], actionable: true))
        XCTAssertTrue(m(actions: [], actionable: false))
        XCTAssertTrue(m(actions: [], actionable: nil))
    }

    func testCombinedFiltersAreConjunctive() {
        XCTAssertTrue(m(role: "AXLink", label: "Apply now", actions: ["AXPress"],
                        query: "apply", roleFilter: "link", actionable: true))
        // Same element, wrong role filter → no match (query alone isn't enough).
        XCTAssertFalse(m(role: "AXButton", label: "Apply now", actions: ["AXPress"],
                         query: "apply", roleFilter: "link", actionable: true))
    }
}

final class FindSearchTests: XCTestCase {
    /// A non-positive `limit` must yield nothing — the guard returns before any AX walk, so this
    /// needs no live tree. Regression test for the cap being applied only after the first append.
    func testNonPositiveLimitReturnsNothing() {
        let registry = ElementRegistry()
        XCTAssertTrue(registry.search(pid: 0, limit: 0).matches.isEmpty)
        XCTAssertTrue(registry.search(pid: 0, limit: -5).matches.isEmpty)
        XCTAssertEqual(registry.search(pid: 0, limit: 0).diagnostics.scanned, 0)
    }
}

/// The press(name) ranking — pure, so it's exercised without a live AX tree.
final class PressSelectionTests: XCTestCase {
    private func c(_ label: String, _ ref: String = "e1") -> PressByNameTool.Candidate {
        PressByNameTool.Candidate(ref: ref, label: label, role: "button")
    }

    func testExactSinglePresses() {
        XCTAssertEqual(PressByNameTool.select([c("Sign in")], name: "Sign in"), .press(c("Sign in")))
    }

    func testCaseInsensitiveExactPresses() {
        XCTAssertEqual(PressByNameTool.select([c("SIGN IN")], name: "sign in"), .press(c("SIGN IN")))
    }

    func testSubstringSinglePresses() {
        XCTAssertEqual(PressByNameTool.select([c("Sign in now")], name: "Sign in"), .press(c("Sign in now")))
    }

    func testExactBeatsSubstring() {
        let exact = c("Save", "e1")
        let substring = c("Save As…", "e2")
        XCTAssertEqual(PressByNameTool.select([substring, exact], name: "Save"), .press(exact))
    }

    func testTwoExactAreAmbiguous() {
        let a = c("Save", "e1")
        let b = c("Save", "e2")
        XCTAssertEqual(PressByNameTool.select([a, b], name: "Save"), .ambiguous([a, b]))
    }

    func testEquallyRankedSubstringsAreAmbiguous() {
        let a = c("Save As…", "e1")
        let b = c("Save Draft", "e2")
        XCTAssertEqual(PressByNameTool.select([a, b], name: "Save"), .ambiguous([a, b]))
    }

    func testNoLabelContainsNameIsNoMatch() {
        XCTAssertEqual(PressByNameTool.select([c("Cancel")], name: "Save"), .noMatch)
    }

    func testEmptyCandidatesIsNoMatch() {
        XCTAssertEqual(PressByNameTool.select([], name: "Save"), .noMatch)
    }
}
