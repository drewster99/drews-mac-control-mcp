//
//  AXElement.swift
//  AXKit
//
//  Lean value wrapper around AXUIElement for the server's read path. Each reader is a synchronous
//  cross-process XPC call, run on the host's serialized request thread. (Adapted from the proven
//  patterns in the app's Core/AXElement.swift, minus the inspector-only formatting.)
//

import ApplicationServices
import CoreGraphics
import Foundation

public struct AXElement: @unchecked Sendable {
    public let raw: AXUIElement

    public init(_ raw: AXUIElement) { self.raw = raw }

    public static func application(pid: pid_t) -> AXElement {
        AXElement(AXUIElementCreateApplication(pid))
    }

    public static func systemWide() -> AXElement {
        AXElement(AXUIElementCreateSystemWide())
    }

    /// Sets the AX messaging timeout for calls made through THIS reference only — per
    /// `AXUIElementSetMessagingTimeout` it does not apply to children, nor even to other references
    /// CFEqual to this one. Exception: on the system-wide element it sets the PROCESS-GLOBAL timeout.
    /// 0 means "use the current global" (or, on the system-wide element, "reset the global to its
    /// default").
    public func setMessagingTimeout(_ seconds: Float) {
        _ = AXUIElementSetMessagingTimeout(raw, seconds)
    }

    /// Owning process — local call, no XPC.
    public var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(raw, &pid) == .success ? pid : nil
    }

    public func copyAttribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(raw, name as CFString, &value) == .success ? value : nil
    }

    public func stringAttribute(_ name: String) -> String? {
        copyAttribute(name) as? String
    }

    public var role: String? { stringAttribute(kAXRoleAttribute) }
    public var subrole: String? { stringAttribute(kAXSubroleAttribute) }
    public var title: String? { stringAttribute(kAXTitleAttribute) }
    public var identifier: String? { stringAttribute("AXIdentifier") }

    /// String form of AXValue — handles the common String and NSNumber cases.
    public var value: String? {
        guard let value = copyAttribute(kAXValueAttribute) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    public var isValueSettable: Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(raw, kAXValueAttribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    /// Whether `attribute` is writable on this element (`AXUIElementIsAttributeSettable`).
    public func isSettable(_ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(raw, attribute as CFString, &settable) == .success && settable.boolValue
    }

    /// The selected text range (a zero-length range is the insertion caret). `nil` if the element
    /// doesn't expose a CFRange-typed `AXSelectedTextRange`.
    public var selectedTextRange: CFRange? {
        guard let value = copyAttribute(kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    /// Whether this app element exposes a window yet. Checks `AXChildren` (which lists windows and
    /// populates promptly on launch) as well as `AXWindows` (which can lag empty for seconds after
    /// an app launches) — so launch readiness isn't stalled waiting on `AXWindows`.
    public var hasWindow: Bool {
        if children.contains(where: { $0.role == kAXWindowRole as String }) { return true }
        return !windows.isEmpty
    }

    /// Total character count (`AXNumberOfCharacters`), for sanity-checking a target range.
    public var numberOfCharacters: Int? {
        (copyAttribute(kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
    }

    /// Replace the current selection (or insert at the caret, when the selection is zero-length)
    /// with `text` — the same effect as typing, via the settable `AXSelectedText` attribute. No
    /// keystrokes, no clipboard, no focus needed. Caller must confirm `isSettable` first.
    @discardableResult
    public func setSelectedText(_ text: String) -> Bool {
        AXUIElementSetAttributeValue(raw, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    /// Move the selection/caret to `range` (`AXSelectedTextRange`).
    @discardableResult
    public func setSelectedRange(_ range: CFRange) -> Bool {
        var value = range
        guard let axValue = AXValueCreate(.cfRange, &value) else { return false }
        return AXUIElementSetAttributeValue(raw, kAXSelectedTextRangeAttribute as CFString, axValue) == .success
    }

    public var actions: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(raw, &names) == .success else { return [] }
        return ((names as? [String]) ?? []).map { Self.cleanActionName($0) }
    }

    /// AX action names are single-line tokens ("AXPress"). Some apps leak the *description* of
    /// an NSAccessibilityCustomAction into the names array instead — a multi-line
    /// "Name:Move next\nTarget:0x0\nSelector:(null)" blob whose newlines would break the
    /// line-based snapshot. Reduce such an entry to its display name; collapse any other stray
    /// newlines so a single action can never span lines.
    static func cleanActionName(_ name: String) -> String {
        guard name.contains(where: { $0.isNewline }) else { return name }
        let lines = name.split(whereSeparator: { $0.isNewline })
        if name.hasPrefix("Name:"), let first = lines.first {
            return String(first.dropFirst("Name:".count)).trimmingCharacters(in: .whitespaces)
        }
        return lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    public var attributeNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(raw, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    public var parameterizedAttributeNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(raw, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    public var children: [AXElement] {
        guard let array = copyAttribute(kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return array.map(AXElement.init)
    }

    public var frame: CGRect? {
        guard let positionValue = copyAttribute(kAXPositionAttribute),
              let sizeValue = copyAttribute(kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        let position = unsafeDowncast(positionValue, to: AXValue.self)
        let dimensions = unsafeDowncast(sizeValue, to: AXValue.self)
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(dimensions) == .cgSize else { return nil }
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(dimensions, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Snapshot fields read in ONE bulk IPC call rather than ~8 separate cross-process round-trips.
    public struct SnapshotAttributes {
        public var role: String?
        public var subrole: String?
        public var identifier: String?
        public var title: String?
        public var value: String?
        public var frame: CGRect?
        public var children: [AXElement]
        // The remaining text fields control_app renders/searches on. Defaulted so older call sites
        // that don't supply them still compile; the bulk read populates them.
        public var axDescription: String? = nil
        public var help: String? = nil
        public var valueDescription: String? = nil
        public var placeholder: String? = nil
        public var url: String? = nil
    }

    /// Read role/subrole/identifier/title/value/frame/children in a single
    /// `AXUIElementCopyMultipleAttributeValues` call. Decodes each field with the SAME logic as the
    /// per-attribute accessors (error/null placeholders → nil), and falls back to those accessors
    /// entirely if the bulk call fails — so the result is equivalent, just far fewer IPC round-trips.
    public func snapshotAttributes() -> SnapshotAttributes {
        let names: [String] = [
            kAXRoleAttribute as String, kAXSubroleAttribute as String, "AXIdentifier",
            kAXTitleAttribute as String, kAXValueAttribute as String,
            kAXPositionAttribute as String, kAXSizeAttribute as String, kAXChildrenAttribute as String,
            "AXDescription", "AXHelp", "AXValueDescription", "AXPlaceholderValue", "AXURL"
        ]
        var out: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(raw, names as CFArray, AXCopyMultipleAttributeOptions(), &out)
        guard err == .success, let values = out as? [AnyObject], values.count == names.count else {
            // Bulk read unsupported/failed — fall back to per-attribute reads (unchanged semantics).
            return SnapshotAttributes(role: role, subrole: subrole, identifier: identifier,
                                      title: title, value: value, frame: frame, children: children,
                                      axDescription: axDescription, help: help,
                                      valueDescription: valueDescription, placeholder: placeholderValue, url: url)
        }

        // A failed attribute comes back as an AXValue of type .axError (or kCFNull); treat as absent.
        func present(_ index: Int) -> AnyObject? {
            let candidate = values[index]
            if CFGetTypeID(candidate) == AXValueGetTypeID(),
               AXValueGetType(unsafeDowncast(candidate, to: AXValue.self)) == .axError { return nil }
            if CFGetTypeID(candidate) == CFNullGetTypeID() { return nil }
            return candidate
        }
        func string(_ index: Int) -> String? { present(index) as? String }

        var decodedValue: String? {
            guard let raw = present(4) else { return nil }
            if let string = raw as? String { return string }
            if let number = raw as? NSNumber { return number.stringValue }
            return nil
        }
        var decodedFrame: CGRect? {
            guard let positionValue = present(5), let sizeValue = present(6),
                  CFGetTypeID(positionValue) == AXValueGetTypeID(),
                  CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
            var origin = CGPoint.zero
            var size = CGSize.zero
            let position = unsafeDowncast(positionValue, to: AXValue.self)
            let dimensions = unsafeDowncast(sizeValue, to: AXValue.self)
            guard AXValueGetType(position) == .cgPoint, AXValueGetType(dimensions) == .cgSize else { return nil }
            guard AXValueGetValue(position, .cgPoint, &origin),
                  AXValueGetValue(dimensions, .cgSize, &size) else { return nil }
            return CGRect(origin: origin, size: size)
        }
        var decodedChildren: [AXElement] {
            guard let raw = present(7), let array = raw as? [AXUIElement] else { return [] }
            return array.map(AXElement.init)
        }
        var decodedURL: String? {
            guard let raw = present(12) else { return nil }
            if let url = raw as? URL { return url.absoluteString }
            if let url = raw as? NSURL { return url.absoluteString }
            return nil
        }

        return SnapshotAttributes(role: string(0), subrole: string(1), identifier: string(2),
                                  title: string(3), value: decodedValue, frame: decodedFrame,
                                  children: decodedChildren,
                                  axDescription: string(8), help: string(9),
                                  valueDescription: string(10), placeholder: string(11), url: decodedURL)
    }

    /// The element this (system-wide or app) element reports as focused.
    public var focusedElement: AXElement? {
        guard let value = copyAttribute(kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(unsafeDowncast(value, to: AXUIElement.self))
    }

    /// The element's parent in the AX tree (`kAXParentAttribute`), or `nil` at the root.
    public var parent: AXElement? {
        guard let value = copyAttribute(kAXParentAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(unsafeDowncast(value, to: AXUIElement.self))
    }

    /// The window containing this element (`kAXWindowAttribute`), or `nil`. Raising this to be the
    /// key/main window is required before synthetic keystrokes will reach the element — keys go to
    /// the frontmost app's *key window*, so a focused element in a background window won't receive
    /// them.
    public var window: AXElement? {
        guard let value = copyAttribute(kAXWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(unsafeDowncast(value, to: AXUIElement.self))
    }

    /// Whether the element currently holds keyboard focus (`kAXFocusedAttribute` is true) — the
    /// read-back used to confirm a `setFocused()` actually took (some elements accept the set call
    /// but never become first responder).
    public var isFocused: Bool {
        guard let value = copyAttribute(kAXFocusedAttribute),
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    /// Hit-test: the element at a screen point (AX top-left coordinates).
    public func elementAtPosition(x: Float, y: Float) -> AXElement? {
        var out: AXUIElement?
        guard AXUIElementCopyElementAtPosition(raw, x, y, &out) == .success, let element = out else { return nil }
        return AXElement(element)
    }

    /// False only when the element has been destroyed (`kAXErrorInvalidUIElement`).
    /// Other errors/success count as alive — we only want to detect a dead reference.
    public var isAlive: Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(raw, kAXRoleAttribute as CFString, &value) != .invalidUIElement
    }

    // MARK: - Mutators (effect-causing — semantic AX, no synthetic events)

    @discardableResult
    public func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(raw, action as CFString) == .success
    }

    @discardableResult
    public func setValue(_ value: String) -> Bool {
        // Guard settability — writing a CFString to a non-settable or non-string value
        // (slider/checkbox/numeric) would fail or misbehave. (Typed conversion per
        // attribute is a future refinement; today this is the string-value path.)
        guard isValueSettable else { return false }
        return AXUIElementSetAttributeValue(raw, kAXValueAttribute as CFString, value as CFString) == .success
    }

    @discardableResult
    public func setFocused() -> Bool {
        AXUIElementSetAttributeValue(raw, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    // MARK: - Window management (AX writes on a window element)

    @discardableResult
    public func setPosition(_ point: CGPoint) -> Bool {
        var value = point
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return false }
        return AXUIElementSetAttributeValue(raw, kAXPositionAttribute as CFString, axValue) == .success
    }

    @discardableResult
    public func setSize(_ size: CGSize) -> Bool {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else { return false }
        return AXUIElementSetAttributeValue(raw, kAXSizeAttribute as CFString, axValue) == .success
    }

    @discardableResult
    public func setMinimized(_ minimized: Bool) -> Bool {
        let flag: CFBoolean = minimized ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(raw, kAXMinimizedAttribute as CFString, flag) == .success
    }

    @discardableResult
    public func raise() -> Bool {
        AXUIElementPerformAction(raw, kAXRaiseAction as CFString) == .success
    }

    /// The app element's menu bar (for menu-path driving).
    public var menuBar: AXElement? {
        guard let value = copyAttribute(kAXMenuBarAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(unsafeDowncast(value, to: AXUIElement.self))
    }
}

// MARK: - control_app enrichment (labels, values, ranges, links, generic booleans, collections)

public extension AXElement {
    /// Numeric attribute reader (NSNumber-backed AX values).
    func numberAttribute(_ name: String) -> Double? {
        (copyAttribute(name) as? NSNumber)?.doubleValue
    }

    /// Array-of-elements attribute reader (rows/cells/etc.).
    func elementArrayAttribute(_ name: String) -> [AXElement]? {
        guard let array = copyAttribute(name) as? [AXUIElement] else { return nil }
        return array.map(AXElement.init)
    }

    /// Accessibility description / help — the 2nd and 3rd label fallbacks after AXTitle (§7).
    var axDescription: String? { stringAttribute("AXDescription") }
    var help: String? { stringAttribute("AXHelp") }

    /// AXValue as a number when the control's value is numeric (slider/scrollbar/stepper).
    var numericValue: Double? { (copyAttribute(kAXValueAttribute) as? NSNumber)?.doubleValue }
    var valueIsNumeric: Bool { numericValue != nil }

    var minValue: Double? { numberAttribute("AXMinValue") }
    var maxValue: Double? { numberAttribute("AXMaxValue") }
    var valueDescription: String? { stringAttribute("AXValueDescription") }
    var placeholderValue: String? { stringAttribute("AXPlaceholderValue") }

    /// AXURL destination as an absolute string (links, web areas, some images).
    var url: String? { (copyAttribute("AXURL") as? NSURL)?.absoluteString }

    /// Whether the element is enabled (`AXEnabled`). Defaults to `true` when the attribute is absent —
    /// many elements that don't expose it are still interactive, so absence shouldn't read as disabled.
    var isEnabled: Bool { (copyAttribute("AXEnabled") as? Bool) ?? true }

    /// Every boolean-typed attribute, name → value. The generic state source (§8); the
    /// renderer surfaces the true ones (with AXEnabled inverted to `disabled`).
    ///
    /// Read in ONE bulk `AXUIElementCopyMultipleAttributeValues` rather than one cross-process call
    /// per attribute name — this runs for every node of the control_app walk, whose budget is
    /// wall-clock-bound, so the ~15-40 round trips it used to cost directly reduced how much of an
    /// app's UI fit in that budget. The payload is unchanged (the per-attribute loop already copied
    /// each of those values); only the number of round trips drops.
    var booleanAttributes: [String: Bool] {
        let names = attributeNames
        guard !names.isEmpty else { return [:] }
        var result: [String: Bool] = [:]

        var out: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(raw, names as CFArray, AXCopyMultipleAttributeOptions(), &out)
        if err == .success, let values = out as? [AnyObject], values.count == names.count {
            // A failed slot comes back as an AXValue of type .axError (or kCFNull); neither is a
            // CFBoolean, so the type check below skips it exactly as a failed single read did.
            for (index, name) in names.enumerated() where CFGetTypeID(values[index]) == CFBooleanGetTypeID() {
                result[name] = CFBooleanGetValue(unsafeDowncast(values[index], to: CFBoolean.self))
            }
            return result
        }

        // Bulk read unsupported/failed — fall back to per-attribute reads (unchanged semantics).
        for name in names {
            guard let value = copyAttribute(name), CFGetTypeID(value) == CFBooleanGetTypeID() else { continue }
            result[name] = CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
        }
        return result
    }

    /// Raw (uncleaned) action names — the exact strings `AXUIElementPerformAction` needs (§9).
    var rawActionNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(raw, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    /// Immediate-child count — one cheap read for the `[N hidden]` marker (§5). `nil` when the
    /// read fails (→ `[more hidden]`).
    var childCount: Int? {
        guard let array = copyAttribute(kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        return array.count
    }

    // Disclosure (outline rows)
    var disclosureLevel: Int? { numberAttribute("AXDisclosureLevel").map { Int($0) } }
    var isDisclosing: Bool? {
        guard let value = copyAttribute("AXDisclosing"), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }
    var isDisclosingSettable: Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(raw, "AXDisclosing" as CFString, &settable) == .success && settable.boolValue
    }
    @discardableResult
    func setDisclosing(_ flag: Bool) -> Bool {
        AXUIElementSetAttributeValue(raw, "AXDisclosing" as CFString, flag ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    // Collections (table/grid/outline) — efficient subset attributes (§10)
    var rowCount: Int? { numberAttribute("AXRowCount").map { Int($0) } }
    var columnCount: Int? { numberAttribute("AXColumnCount").map { Int($0) } }
    var columnTitles: [String]? { copyAttribute("AXColumnTitles") as? [String] }
    var visibleRows: [AXElement]? { elementArrayAttribute("AXVisibleRows") }
    var selectedRows: [AXElement]? { elementArrayAttribute("AXSelectedRows") }
    var visibleCells: [AXElement]? { elementArrayAttribute("AXVisibleCells") }
    var selectedCells: [AXElement]? { elementArrayAttribute("AXSelectedCells") }

    /// The app element's windows in `AXWindows` order (native / best-effort z-order, §4).
    var windows: [AXElement] { elementArrayAttribute("AXWindows") ?? [] }

    /// The point AX recommends for activating this element (`AXActivationPoint`), in top-left
    /// screen coordinates — the right place to synthesize a click for `activate`.
    var activationPoint: CGPoint? {
        guard let value = copyAttribute("AXActivationPoint"), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    /// Numeric value setter (slider/scrollbar) — writes a `CFNumber`, guarded by settability.
    @discardableResult
    func setValue(number: Double) -> Bool {
        guard isValueSettable else { return false }
        return AXUIElementSetAttributeValue(raw, kAXValueAttribute as CFString, NSNumber(value: number)) == .success
    }
}

// AX guarantees two AXUIElementRefs to the same element are CFEqual — this is what lets
// the session assign a STABLE ref to an element across snapshots (so diffs are meaningful).
extension AXElement: Hashable {
    public static func == (lhs: AXElement, rhs: AXElement) -> Bool {
        CFEqual(lhs.raw, rhs.raw)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(raw))
    }
}
