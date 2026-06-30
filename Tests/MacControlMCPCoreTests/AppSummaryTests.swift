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
        XCTAssertEqual(summary.menus, [AppSummary.Menu(title: "File", items: ["New Note"])])   // Quit + all-of-Edit filtered
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
        XCTAssertTrue(text.contains("File: New Note"))
        XCTAssertTrue(text.contains("Active window: Vacation plan"))
        XCTAssertTrue(text.contains("Buttons: Save, Cancel [+1 unnamed]"))
        XCTAssertTrue(text.contains("Text fields: Title =\"My note\""))
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

    func testStandardMenuFilter() {
        XCTAssertTrue(AppProjection.isStandardMenuItem("Quit Notes"))
        XCTAssertTrue(AppProjection.isStandardMenuItem("About Safari"))
        XCTAssertTrue(AppProjection.isStandardMenuItem("Paste"))
        XCTAssertFalse(AppProjection.isStandardMenuItem("New Note"))
        XCTAssertFalse(AppProjection.isStandardMenuItem("Export as PDF…"))
    }
}
