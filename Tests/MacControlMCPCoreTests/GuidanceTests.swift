import XCTest
@testable import MacControlMCPCore

/// The `guidance` block: the verb catalog, the containers a result is quietly holding back, and the
/// concrete next calls built from the refs a response actually returned.
final class GuidanceTests: XCTestCase {

    private func deviceApp() -> ControlNode {
        ControlNode(ref: "e1", type: "application", label: "Device Hub", children: [
            ControlNode(ref: "e2", type: "window", label: "iPhone 17", states: ["main"], children: [
                ControlNode(ref: "e10", type: "button", label: "Home", actions: ["press"]),
                ControlNode(ref: "e11", type: Guidance.deviceScreenType, children: [
                    ControlNode(ref: "e12", type: "button", label: "Fitness", actions: ["press"])
                ])
            ]),
            ControlNode(ref: "e3", type: "window", label: "iPhone 17 Pro", children: [
                ControlNode(ref: "e20", type: "outline", label: "Sidebar", hidden: .unknown),
                ControlNode(ref: "e21", type: "table", label: "Devices", hidden: .known(243))
            ])
        ])
    }

    // MARK: content the tree doesn't announce

    func testDeviceScreenIsReportedPerWindowWithItsRef() {
        let pending = Guidance.pendingContent(in: deviceApp())
        let device = try? XCTUnwrap(pending.first)
        XCTAssertEqual(device?.ref, "e11")
        XCTAssertEqual(device?.windowTitle, "iPhone 17")
        XCTAssertTrue(device?.isDeviceScreen == true)

        let lines = Guidance.pendingContentLines(pending)
        XCTAssertTrue(lines.contains { $0.contains("iPhone 17") && $0.contains(#"expand(ref: "e11")"#) },
                      lines.joined(separator: "\n"))
    }

    /// The whole point of the device case: a mirrored screen reports no hidden count, so without an
    /// explicit rule nothing in the output would suggest there is more to load.
    func testDeviceScreenIsFoundEvenThoughItAnnouncesNoHiddenChildren() {
        let screen = ControlNode(ref: "e11", type: Guidance.deviceScreenType)
        XCTAssertEqual(screen.hidden, HiddenCount.none)
        let pending = Guidance.pendingContent(in: deviceApp())
        XCTAssertTrue(pending.contains { $0.ref == "e11" && $0.isDeviceScreen })
    }

    func testHiddenChildrenAreReportedWithTheirCount() {
        let pending = Guidance.pendingContent(in: deviceApp())
        let table = pending.first { $0.ref == "e21" }
        XCTAssertEqual(table?.windowTitle, "iPhone 17 Pro")
        XCTAssertEqual(table?.isDeviceScreen, false)
        XCTAssertTrue(table?.describedAs.contains("243") == true, table?.describedAs ?? "nil")
    }

    func testDeviceScreensSortAheadOfMerelyHiddenContainers() {
        let pending = Guidance.pendingContent(in: deviceApp())
        XCTAssertEqual(pending.first?.isDeviceScreen, true)
    }

    func testNothingPendingProducesNoHeading() {
        let plain = ControlNode(ref: "e1", type: "application", label: "X", children: [
            ControlNode(ref: "e2", type: "window", label: "W", children: [
                ControlNode(ref: "e3", type: "button", label: "OK", actions: ["press"])
            ])
        ])
        XCTAssertTrue(Guidance.pendingContent(in: plain).isEmpty)
        XCTAssertTrue(Guidance.pendingContentLines([]).isEmpty)
    }

    // MARK: next steps wired to real refs

    func testNextStepsUseTheAppsOwnRefs() {
        let tree = ControlNode(ref: "e1", type: "application", label: "Notes", children: [
            ControlNode(ref: "e2", type: "window", label: "All iCloud", states: ["main"], children: [
                ControlNode(ref: "e5", type: "button", label: "New Note", actions: ["press"]),
                ControlNode(ref: "e6", type: "textField", label: "Search", textValue: "")
            ])
        ])
        let summary = AppProjection.project(tree: tree, name: "Notes", pid: 42, bundleId: "com.apple.Notes")
        let lines = Guidance.forAppSummary(summary, pending: Guidance.pendingContent(in: tree))
        let text = lines.joined(separator: "\n")

        XCTAssertTrue(text.contains(#"action("e5", "press")"#), text)
        XCTAssertTrue(text.contains(#"change_text("e6", "your text")"#), text)
        XCTAssertTrue(text.contains("find_elements(pid: 42"), text)
        XCTAssertTrue(text.contains(#"control_app(identity: "com.apple.Notes")"#), text)
        // Named, so the caller can tell which control a suggestion would hit.
        XCTAssertTrue(text.contains("\"New Note\""), text)
    }

    func testGuidanceCarriesTheRealPidNotAPlaceholder() {
        let tree = ControlNode(ref: "e1", type: "application", label: "X", children: [
            ControlNode(ref: "e2", type: "window", label: "W", states: ["main"])
        ])
        let summary = AppProjection.project(tree: tree, name: "X", pid: 5016, bundleId: "com.x")
        let text = Guidance.forAppSummary(summary, pending: []).joined(separator: "\n")
        XCTAssertTrue(text.contains("pid (5016)"), text)
        XCTAssertTrue(text.contains("wait_for(pid: 5016"), text)
        XCTAssertFalse(text.contains("pid: N"), text)
    }

    // MARK: per-element guidance

    func testElementGuidanceNamesTheActionsTheElementReports() {
        let lines = Guidance.forElement(ref: "e14", actions: ["press", "menu"], isSettable: false)
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.contains(#"action("e14", "press")"#), text)
        XCTAssertTrue(text.contains(#"action("e14", "menu")"#), text)
        XCTAssertTrue(text.contains(#"click("e14")"#), text)
    }

    func testSettableElementIsOfferedAWrite() {
        let text = Guidance.forElement(ref: "e10", actions: [], isSettable: true).joined(separator: "\n")
        XCTAssertTrue(text.contains(#"change_text("e10", "your text")"#), text)
    }

    func testActionlessElementFallsBackToClickAndReveal() {
        let text = Guidance.forElement(ref: "e9", actions: [], isSettable: false).joined(separator: "\n")
        XCTAssertTrue(text.contains(#"click("e9")"#), text)
        XCTAssertTrue(text.contains(#"reveal("e9")"#), text)
    }

    // MARK: one catalog, two consumers

    /// The legend renders its verb block from `Guidance.refVerbs`, so a verb documented for `app`
    /// is by construction the same verb documented for `control_app`.
    func testLegendRendersEveryCatalogVerb() {
        for verb in Guidance.refVerbs {
            XCTAssertTrue(ControlRenderer.legend.contains(verb.call),
                          "legend is missing \(verb.call) — catalog and legend have drifted")
        }
    }

    func testVerbLinesAlignPurposesIntoOneColumn() {
        // Distinct purposes with no shared substring, so each is located where it actually starts.
        let lines = Guidance.verbLines([.init(call: "a(ref)", purpose: "alpha"),
                                        .init(call: "muchLongerCall(ref)", purpose: "beta")])
        let columns = zip(lines, ["alpha", "beta"]).map { line, purpose -> Int in
            line.range(of: purpose).map { line.distance(from: line.startIndex, to: $0.lowerBound) } ?? -1
        }
        XCTAssertEqual(columns[0], columns[1], lines.joined(separator: "\n"))
    }

    /// Regression: the per-window cap used to be applied while walking, so a window whose hidden
    /// containers were walked first would push its device screen out of the list — losing the one
    /// line nothing else in the output would have revealed.
    func testDeviceScreenSurvivesAWindowFullOfHiddenContainers() {
        let tree = ControlNode(ref: "e1", type: "application", label: "Hub", children: [
            ControlNode(ref: "e2", type: "window", label: "iPhone", states: ["main"], children: [
                ControlNode(ref: "h1", type: "outline", label: "One", hidden: .unknown),
                ControlNode(ref: "h2", type: "outline", label: "Two", hidden: .unknown),
                ControlNode(ref: "h3", type: "outline", label: "Three", hidden: .unknown),
                ControlNode(ref: "h4", type: "outline", label: "Four", hidden: .unknown),
                ControlNode(ref: "screen", type: Guidance.deviceScreenType)
            ])
        ])
        let pending = Guidance.pendingContent(in: tree)
        XCTAssertTrue(pending.contains { $0.ref == "screen" },
                      "device screen was crowded out: \(pending.map(\.ref))")
        XCTAssertEqual(pending.first?.ref, "screen")
    }

    /// Regression: titles are app-supplied. An unescaped quote used to end the suggested call early,
    /// handing the caller something they could not paste.
    func testQuotesInTitlesDoNotBreakASuggestedCall() {
        let tree = ControlNode(ref: "e1", type: "application", label: "X", children: [
            ControlNode(ref: "e2", type: "window", label: #"He said "hi""#, states: ["main"], children: [
                ControlNode(ref: "e3", type: Guidance.deviceScreenType)
            ])
        ])
        let line = Guidance.pendingContentLines(Guidance.pendingContent(in: tree)).joined(separator: "\n")
        XCTAssertTrue(line.contains(#"He said \"hi\""#), line)
        XCTAssertTrue(line.contains(#"expand(ref: "e3")"#), line)
    }

    /// Regression: the generated verb block is interpolated into the legend, so it does not get the
    /// `"""`-literal indentation stripping the hand-written sections get. It once rendered four
    /// spaces deeper than every other legend line.
    func testEveryLegendLineIsFlushCommentText() {
        for line in ControlRenderer.legend.split(separator: "\n", omittingEmptySubsequences: false) {
            guard !line.isEmpty else { continue }
            XCTAssertTrue(line.hasPrefix("//"), "legend line is indented: \(String(reflecting: String(line)))")
        }
    }
}
