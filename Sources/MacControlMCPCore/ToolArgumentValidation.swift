//
//  ToolArgumentValidation.swift
//  MacControlMCPCore
//
//  Rejects arguments a tool does not declare, so a caller learns it made a mistake instead of
//  getting a confident answer to a question it did not ask.
//
//  Before this, an unrecognized key was dropped without a word. That is harmless for a stray extra,
//  but the common case is a *misspelled optional*: `open(target:…, backround: true)` silently took
//  `background`'s `?? false` default, opened the app in the foreground, stole focus, and returned a
//  success payload. Every argument a tool honors is declared in its own `inputSchema`, so that
//  schema is the authority on what is acceptable — no separate list to keep in step with it.
//
//  Where this runs matters. It validates the arguments the *caller* sent, at the point they enter
//  the server, before any wrapper has touched them: `DeferringTool` injects a `timeout` into the
//  inner tool's arguments for tools whose schema never mentions one, so validating any later would
//  reject the server's own bookkeeping. `BatchTool` applies the same check to each step's arguments
//  before dispatching it, since those never pass through the entry point.
//

import Foundation

/// The verdict on one tool call's arguments.
public enum ToolArgumentValidation {

    /// The parameter names a tool's `inputSchema` declares.
    ///
    /// A schema with no `properties` object declares nothing, which means the tool takes no
    /// arguments — not that it accepts anything. `version` and `check_user_activity` are in that
    /// position and should reject a stray key like any other tool.
    public static func declaredParameterNames(of tool: Tool) -> Set<String> {
        guard let schema = tool.descriptor["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any] else { return [] }
        return Set(properties.keys)
    }

    /// The supplied names the tool does not declare, sorted so the message is stable across runs.
    public static func unknownParameterNames(in arguments: [String: Any],
                                             declaredNames: Set<String>) -> [String] {
        arguments.keys.filter { !declaredNames.contains($0) }.sorted()
    }

    /// A structured rejection for the unknown names, or `nil` when every argument is recognized.
    ///
    /// The payload names what was rejected, what the tool does accept, and — for a near-miss — the
    /// name that was probably meant, because a misspelling is the failure this is here to catch and
    /// the caller can act on a suggestion without re-reading the schema.
    public static func rejection(for arguments: [String: Any], tool: Tool) -> [String: Any]? {
        rejection(for: arguments, toolName: tool.name, declaredNames: declaredParameterNames(of: tool))
    }

    /// The same verdict for a caller that has the declared names but not the `Tool` itself.
    /// `BatchTool` is deliberately built without tool knowledge — it is handed a dispatcher, not a
    /// registry — so it validates through this rather than acquiring a lookup it should not have.
    public static func rejection(for arguments: [String: Any], toolName: String,
                                 declaredNames: Set<String>) -> [String: Any]? {
        let unknown = unknownParameterNames(in: arguments, declaredNames: declaredNames)
        guard !unknown.isEmpty else { return nil }

        var payload: [String: Any] = [
            "ok": false,
            "error": "unknown_parameter",
            "tool": toolName,
            "unknownParameters": unknown,
            "acceptedParameters": declaredNames.sorted(),
        ]

        var suggestions: [String: String] = [:]
        for name in unknown {
            if let match = closestName(to: name, among: declaredNames) { suggestions[name] = match }
        }
        if !suggestions.isEmpty { payload["didYouMean"] = suggestions }
        payload["howToFix"] = howToFix(unknown: unknown, suggestions: suggestions,
                                       declaredNames: declaredNames, tool: toolName)
        return payload
    }

    private static func howToFix(unknown: [String], suggestions: [String: String],
                                 declaredNames: Set<String>, tool: String) -> String {
        if let name = unknown.first, let match = suggestions[name], unknown.count == 1 {
            return "`\(tool)` has no `\(name)` parameter — did you mean `\(match)`?"
        }
        let listed = unknown.map { "`\($0)`" }.joined(separator: ", ")
        if declaredNames.isEmpty {
            return "`\(tool)` takes no arguments, so \(listed) cannot be passed."
        }
        let accepted = declaredNames.sorted().map { "`\($0)`" }.joined(separator: ", ")
        return "`\(tool)` does not accept \(listed). It accepts: \(accepted)."
    }

    /// The declared name closest to `name`, or `nil` when nothing is close enough to be worth
    /// suggesting. The threshold scales with length so short names need a near-exact match — at a
    /// fixed distance of two, every three-letter name would "suggest" every other one.
    static func closestName(to name: String, among declaredNames: Set<String>) -> String? {
        let lowered = name.lowercased()
        // A pure case difference is the most likely miss of all, and edit distance would rank it
        // level with a genuine typo; take it directly.
        if let exact = declaredNames.first(where: { $0.lowercased() == lowered }) { return exact }

        let budget = max(1, min(3, name.count / 3))
        var best: (name: String, distance: Int)?
        for candidate in declaredNames.sorted() {
            let distance = editDistance(lowered, candidate.lowercased())
            guard distance <= budget else { continue }
            if best == nil || distance < best!.distance { best = (candidate, distance) }
        }
        return best?.name
    }

    /// Levenshtein distance, two rows rather than a full matrix — the inputs are parameter names,
    /// so this runs on a handful of very short strings per rejected call.
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs), right = Array(rhs)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }

        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)
        for i in 1...left.count {
            current[0] = i
            for j in 1...right.count {
                let substitution = previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[right.count]
    }
}
