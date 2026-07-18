//
//  PasteOutcome.swift
//  MacControlMCPCore
//

import Foundation

/// What happened to a synthetic ⌘V paste and the user's clipboard afterward.
public struct PasteOutcome: Sendable {
    public enum ClipboardRestore: String, Sendable {
        /// Snapshot written back successfully.
        case restored
        /// Someone else wrote the pasteboard during the hold; their content wins.
        case skippedExternalWrite = "skipped_external_write"
        /// Restore write failed twice — the user's clipboard was lost.
        case failed
        /// The pasteboard was empty before the paste.
        case nothingToRestore = "nothing_to_restore"
    }

    /// The ⌘V chord's events were created and posted.
    public let posted: Bool
    public let clipboardRestore: ClipboardRestore
    /// How long the clipboard held our text before restore/skip.
    public let heldMs: Int

    public init(posted: Bool, clipboardRestore: ClipboardRestore, heldMs: Int) {
        self.posted = posted
        self.clipboardRestore = clipboardRestore
        self.heldMs = heldMs
    }
}
