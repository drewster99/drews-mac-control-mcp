import XCTest
@testable import MacControlMCPCore

final class AppSummaryTests: XCTestCase {
    private func fixture() -> ControlNode {
        ControlNode(ref: "e1", type: "application", label: "Notes", children: [
            ControlNode(ref: "e2", type: "menuBar", children: [
                ControlNode(ref: "e3", type: "menuBarItem", label: "File", children: [
                    ControlNode(ref: "e4", type: "menu", label: "File", children: [
                        ControlNode(ref: "e5", type: "menuItem", label: "New Note"),
                        ControlNode(ref: "e6", type: "menuItem", label: "Quit Notes")   // standard → filtered
                    ])
                ]),
                ControlNode(ref: "e7", type: "menuBarItem", label: "Edit", children: [
                    ControlNode(ref: "e8", type: "menu", label: "Edit", children: [
                        ControlNode(ref: "e9", type: "menuItem", label: "Undo")          // standard → Edit drops out
                    ])
                ])
            ]),
            ControlNode(ref: "e10", type: "window", label: "Vacation plan", states: ["main"], children: [
                ControlNode(ref: "e11", type: "button", label: "Save"),
                ControlNode(ref: "e12", type: "button", label: "Cancel"),
                ControlNode(ref: "e13", type: "button"),                                  // unnamed → elision
                ControlNode(ref: "e14", type: "textField", label: "Title", textValue: "My note", states: ["editable"]),
                ControlNode(ref: "e15", type: "link", label: "Open", actions: ["press"]),
                ControlNode(ref: "e16", type: "staticText", label: "Some label")
            ]),
            ControlNode(ref: "e17", type: "window", label: "New Note")
        ])
    }

    func testProjection() {
        let summary = AppProjection.project(tree: fixture(), name: "Notes", pid: 123, bundleId: "com.apple.Notes")
        XCTAssertEqual(summary.name, "Notes")
        XCTAssertEqual(summary.pid, 123)
        XCTAssertEqual(summary.windows, ["Vacation plan", "New Note"])
        XCTAssertEqual(summary.menus, ["File", "Edit"])   // titles only
        XCTAssertEqual(summary.activeWindow?.title, "Vacation plan")

        let groups = Dictionary(uniqueKeysWithValues: (summary.activeWindow?.groups ?? []).map { ($0.name, $0) })
        XCTAssertEqual(groups["Buttons"]?.entries, ["Save", "Cancel"])
        XCTAssertEqual(groups["Buttons"]?.unnamed, 1)
        XCTAssertEqual(groups["Text fields"]?.entries, ["Title =\"My note\""])
        XCTAssertEqual(groups["Other"]?.entries, ["Open (link)"])
        XCTAssertEqual(groups["Text"]?.entries, ["\"Some label\""])
    }

    func testRender() {
        let summary = AppProjection.project(tree: fixture(), name: "Notes", pid: 123, bundleId: "com.apple.Notes")
        let text = AppRenderer.render(summary)
        XCTAssertTrue(text.contains("App: Notes  pid 123  com.apple.Notes"))
        XCTAssertTrue(text.contains("Windows: Vacation plan, New Note"))
        XCTAssertTrue(text.contains("Menus: File, Edit"))
        XCTAssertTrue(text.contains("Active window: Vacation plan"))
        XCTAssertTrue(text.contains("Buttons (2): Save, Cancel [+1 unnamed]"))
        XCTAssertTrue(text.contains("Text fields (1): Title =\"My note\""))
    }

    func testActiveWindowOverride() {
        let summary = AppProjection.project(tree: fixture(), name: "Notes", pid: 123,
                                            bundleId: "com.apple.Notes", activeWindowTitle: "New Note")
        XCTAssertEqual(summary.activeWindow?.title, "New Note")
    }

    func testActiveWindowSubstringMatch() {
        // Window-title resolution is substring-based, so a substring hint picks the right window.
        let summary = AppProjection.project(tree: fixture(), name: "Notes", pid: 123,
                                            bundleId: "com.apple.Notes", activeWindowTitle: "New")
        XCTAssertEqual(summary.activeWindow?.title, "New Note")
    }

    func testDialogSubroleCountsAsWindow() {
        // Safari's window is an AXWindow with subrole AXDialog → humanized type "dialog".
        let tree = ControlNode(ref: "e1", type: "application", label: "Safari", children: [
            ControlNode(ref: "e2", type: "menuBar"),
            ControlNode(ref: "e3", type: "dialog", label: "macOS26/Agent", states: ["main"], children: [
                ControlNode(ref: "e4", type: "button", label: "Reload")
            ])
        ])
        let summary = AppProjection.project(tree: tree, name: "Safari", pid: 1, bundleId: "com.apple.Safari")
        XCTAssertEqual(summary.windows, ["macOS26/Agent"])
        XCTAssertEqual(summary.activeWindow?.title, "macOS26/Agent")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: (summary.activeWindow?.groups ?? []).map { ($0.name, $0) })["Buttons"]?.entries, ["Reload"])
    }

    func testNewlinesAreEscapedEverywhere() {
        let tree = ControlNode(ref: "e1", type: "application", label: "X", children: [
            ControlNode(ref: "e2", type: "window", label: "Win\nTwo", states: ["main"], children: [
                ControlNode(ref: "e3", type: "button", label: "Press\nMe"),
                ControlNode(ref: "e4", type: "textField", label: "Body", textValue: "line1\nline2")
            ])
        ])
        let text = AppRenderer.render(AppProjection.project(tree: tree, name: "X", pid: 1, bundleId: "x"))
        XCTAssertTrue(text.contains("Press\\nMe"))                  // escaped
        XCTAssertFalse(text.contains("Press\nMe"))                 // no RAW newline inside a label
        XCTAssertTrue(text.contains("Body =\"line1\\nline2\""))
        XCTAssertTrue(text.contains("Active window: Win\\nTwo"))
    }
}
