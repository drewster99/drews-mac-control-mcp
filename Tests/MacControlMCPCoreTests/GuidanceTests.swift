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

        XCTAssertTrue(text.contains(#"action(ref: "e5", action: "press")"#), text)
        XCTAssertTrue(text.contains(#"change_text(ref: "e6", value: "your text")"#), text)
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
        XCTAssertTrue(text.contains(#"action(ref: "e14", action: "press")"#), text)
        XCTAssertTrue(text.contains(#"action(ref: "e14", action: "menu")"#), text)
        XCTAssertTrue(text.contains(#"click(ref: "e14")"#), text)
    }

    func testSettableElementIsOfferedAWrite() {
        let text = Guidance.forElement(ref: "e10", actions: [], isSettable: true).joined(separator: "\n")
        XCTAssertTrue(text.contains(#"change_text(ref: "e10", value: "your text")"#), text)
    }

    func testActionlessElementFallsBackToClickAndReveal() {
        let text = Guidance.forElement(ref: "e9", actions: [], isSettable: false).joined(separator: "\n")
        XCTAssertTrue(text.contains(#"click(ref: "e9")"#), text)
        XCTAssertTrue(text.contains(#"reveal(ref: "e9")"#), text)
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

    /// Regression: not every running app has a bundle id, and `identity: ""` fails with
    /// missing_identity — so a bundle-less app used to be handed two calls that cannot work.
    func testAppWithNoBundleIdIsGivenAnIdentityThatResolves() {
        let tree = ControlNode(ref: "e1", type: "application", label: "Helper", children: [
            ControlNode(ref: "e2", type: "window", label: "W", states: ["main"], children: [
                ControlNode(ref: "e3", type: "button", label: "Go", actions: ["press"])
            ])
        ])
        let summary = AppProjection.project(tree: tree, name: "Helper", pid: 909, bundleId: "")
        let text = Guidance.nextSteps(for: summary).joined(separator: "\n")
        XCTAssertFalse(text.contains(#"identity: """#), text)
        XCTAssertTrue(text.contains(#"control_app(identity: "909")"#), text)
    }

    func testBundleIdIsPreferredAsTheIdentityWhenPresent() {
        let tree = ControlNode(ref: "e1", type: "application", label: "Notes", children: [
            ControlNode(ref: "e2", type: "window", label: "W", states: ["main"])
        ])
        let summary = AppProjection.project(tree: tree, name: "Notes", pid: 42, bundleId: "com.apple.Notes")
        let text = Guidance.nextSteps(for: summary).joined(separator: "\n")
        XCTAssertTrue(text.contains(#"control_app(identity: "com.apple.Notes")"#), text)
    }

    // MARK: regressions found by audit

    /// `String.padding(toLength:)` measures UTF-16 while the column width counts Characters, so it
    /// TRUNCATED any call whose units exceed its character count — an NFD filename or an emoji in a
    /// window title — cutting off the closing quote and paren.
    func testAlignmentNeverTruncatesANonASCIICall() {
        let nfd = "re\u{0301}sume\u{0301}.pages"          // what the filesystem hands out
        let long = #"app(identity: "com.apple.Pages", window: "\#(nfd)")"#
        let lines = Guidance.verbLines([.init(call: long, purpose: "summarize that window"),
                                        .init(call: #"click(ref: "e1")"#, purpose: "click")])
        XCTAssertTrue(lines[0].contains(long), "the call was cut: \(lines[0])")
        XCTAssertTrue(lines[0].contains(#"")"#), "lost its closing quote/paren: \(lines[0])")

        let emoji = #"app(identity: "com.slack", window: "🎉 Release")"#
        let emojiLines = Guidance.verbLines([.init(call: emoji, purpose: "x"),
                                             .init(call: "a(ref: \"e1\")", purpose: "y")])
        XCTAssertTrue(emojiLines[0].contains(emoji), "emoji call was cut: \(emojiLines[0])")
    }

    /// The window argument used to be the DISPLAY title — truncated at 80 with an ellipsis that no
    /// real window title contains — so the hint matched nothing and `app` silently returned the
    /// window the caller already had.
    func testWindowSuggestionCarriesAMatchableHintNotTheEllipsisedTitle() {
        let longTitle = String(repeating: "Swift Forums — strict concurrency ", count: 4)
        let tree = ControlNode(ref: "e1", type: "application", label: "Safari", children: [
            ControlNode(ref: "e2", type: "window", label: "Main", states: ["main"]),
            ControlNode(ref: "e3", type: "window", label: longTitle)
        ])
        let summary = AppProjection.project(tree: tree, name: "Safari", pid: 9, bundleId: "com.apple.Safari")
        let text = Guidance.nextSteps(for: summary).joined(separator: "\n")
        XCTAssertFalse(text.contains("…"), "an ellipsised title cannot match any window: \(text)")
        let hint = try? XCTUnwrap(summary.windows.first { !$0.isActive }?.matchHint)
        XCTAssertNotNil(hint)
        XCTAssertTrue(longTitle.contains(hint ?? "zzz"), "the hint must be a real substring of the title")
    }

    /// Call arguments must survive a backslash. `AppProjection.quote` escapes quotes only, so a
    /// title like `regex \u{5C}d+` produced an invalid JSON escape, and one ending in a backslash
    /// produced an unterminated string literal.
    func testBackslashesInTitlesDoNotBreakASuggestedCall() {
        let backslash = "\u{5C}"
        let title = "AC" + backslash + "DC" + backslash          // AC\DC\
        let tree = ControlNode(ref: "e1", type: "application", label: "X", children: [
            ControlNode(ref: "e2", type: "window", label: title, states: ["main"], children: [
                ControlNode(ref: "e3", type: Guidance.deviceScreenType)
            ])
        ])
        let line = Guidance.pendingContentLines(Guidance.pendingContent(in: tree)).joined(separator: "\n")
        let escaped = "AC" + backslash + backslash + "DC" + backslash + backslash
        XCTAssertTrue(line.contains(escaped), "backslashes must be doubled: \(line)")
        // The literal must still be terminated: an odd trailing backslash would eat the quote.
        XCTAssertTrue(line.contains(escaped + "\""), "the quoted literal is unterminated: \(line)")
    }

    /// Windows are identified by base role OR subrole everywhere else; matching on `type` alone
    /// skipped any window whose subrole humanizes outside the list — and any device screen in it.
    func testDeviceScreenIsFoundInAWindowWithAnUnusualSubrole() {
        let tree = ControlNode(ref: "e1", type: "application", label: "Java App", children: [
            ControlNode(ref: "e2", type: "unknown", role: "window", label: "Main", children: [
                ControlNode(ref: "e3", type: Guidance.deviceScreenType)
            ])
        ])
        XCTAssertTrue(Guidance.pendingContent(in: tree).contains { $0.ref == "e3" },
                      "a window whose subrole is unusual still contains its device screen")
    }

    /// The per-window budget keyed on TITLE, so two Finder windows both called "Documents" shared
    /// one budget and the second window's unloaded content was dropped entirely.
    func testTwoWindowsWithTheSameTitleEachGetTheirOwnBudget() {
        func window(_ ref: String) -> ControlNode {
            ControlNode(ref: ref, type: "window", label: "Documents", children: [
                ControlNode(ref: ref + "a", type: "outline", label: "One", hidden: .unknown),
                ControlNode(ref: ref + "b", type: "table", label: "Two", hidden: .unknown),
                ControlNode(ref: ref + "c", type: "outline", label: "Three", hidden: .unknown)
            ])
        }
        let tree = ControlNode(ref: "e1", type: "application", label: "Finder",
                               children: [window("w1"), window("w2")])
        let pending = Guidance.pendingContent(in: tree)
        XCTAssertTrue(pending.contains { $0.windowRef == "w1" })
        XCTAssertTrue(pending.contains { $0.windowRef == "w2" },
                      "the second same-titled window must not be starved: \(pending.map(\.ref))")
    }
}
