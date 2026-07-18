//
//  Sim.swift
//  MacControlMCPCore
//
//  The simulator device suite (§5/§8 P5) via `xcrun simctl`. No TCC grant. `udid` defaults
//  to the booted device. Each action returns { ok, output } or { ok:false, error }.
//

import Foundation

public struct SimTool: Tool {
    public init() {}

    public let name = "sim"

    public var descriptor: [String: Any] {
        [
            "name": name,
            "description": "Drive a simulator via simctl: openurl/appearance/statusbar/statusbar_clear/launch/terminate/pbpaste. udid defaults to the booted device. No grant.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["openurl", "appearance", "statusbar", "statusbar_clear", "launch", "terminate", "pbpaste"]],
                    "udid": ["type": "string", "description": "Defaults to the booted device."],
                    "url": ["type": "string"],
                    "value": ["type": "string", "description": "dark|light for appearance."],
                    "bundleId": ["type": "string"]
                ],
                "required": ["action"]
            ]
        ]
    }

    public func call(_ arguments: [String: Any]) -> String {
        guard let action = arguments["action"] as? String else {
            return JSONText.from(["error": "missing_action"])
        }
        let udid = (arguments["udid"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "booted"

        // "booted" or a canonical UUID only. simctl would also accept a device *name*, but a
        // name is caller-supplied free text that could begin with `-` and be parsed as a
        // simctl option; requiring the UDID closes that while list_simulators provides it.
        guard udid == "booted" || UUID(uuidString: udid) != nil else {
            return JSONText.from([
                "error": "invalid_udid", "udid": udid,
                "howToFix": "Pass a simulator UDID (from list_simulators) or omit udid to target the booted device."
            ])
        }

        let simctlArgs: [String]
        switch action {
        case "openurl":
            guard let url = arguments["url"] as? String else { return JSONText.from(["error": "missing_url"]) }
            guard OperandSyntax.looksLikeURL(url) else {
                return JSONText.from([
                    "error": "invalid_url", "url": url,
                    "howToFix": "Pass a URL beginning with a scheme, e.g. https://example.com or myapp://path."
                ])
            }
            simctlArgs = ["simctl", "openurl", udid, url]
        case "appearance":
            guard let value = arguments["value"] as? String else { return JSONText.from(["error": "missing_value"]) }
            guard value == "dark" || value == "light" else {
                return JSONText.from([
                    "error": "invalid_value", "value": value,
                    "howToFix": "Pass \"dark\" or \"light\"."
                ])
            }
            simctlArgs = ["simctl", "ui", udid, "appearance", value]
        case "statusbar":
            simctlArgs = ["simctl", "status_bar", udid, "override",
                          "--time", "9:41", "--batteryState", "charged",
                          "--batteryLevel", "100", "--cellularBars", "4", "--wifiBars", "3"]
        case "statusbar_clear":
            simctlArgs = ["simctl", "status_bar", udid, "clear"]
        case "launch":
            guard let bundleId = arguments["bundleId"] as? String else { return JSONText.from(["error": "missing_bundleId"]) }
            guard isBundleID(bundleId) else {
                return JSONText.from([
                    "error": "invalid_bundleId", "bundleId": bundleId,
                    "howToFix": "Pass a bundle identifier like com.example.MyApp (letters, digits, '.', '-', '_'; must start with a letter or digit)."
                ])
            }
            simctlArgs = ["simctl", "launch", udid, bundleId]
        case "terminate":
            guard let bundleId = arguments["bundleId"] as? String else { return JSONText.from(["error": "missing_bundleId"]) }
            guard isBundleID(bundleId) else {
                return JSONText.from([
                    "error": "invalid_bundleId", "bundleId": bundleId,
                    "howToFix": "Pass a bundle identifier like com.example.MyApp (letters, digits, '.', '-', '_'; must start with a letter or digit)."
                ])
            }
            simctlArgs = ["simctl", "terminate", udid, bundleId]
        case "pbpaste":
            simctlArgs = ["simctl", "pbpaste", udid]
        default:
            return JSONText.from(["error": "unknown_action", "action": action])
        }

        let result = Shell.runFull("/usr/bin/xcrun", simctlArgs)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status == 0 {
            return JSONText.from(["ok": true, "action": action, "output": output])
        }
        return JSONText.from(["ok": false, "action": action, "error": output])
    }

    /// True when `string` fits bundle-identifier grammar: an ASCII letter/digit first (so it can
    /// never start with `-` and be parsed as a simctl option), then ASCII letters/digits/./-/_.
    private func isBundleID(_ string: String) -> Bool {
        guard let first = string.unicodeScalars.first,
              first.isASCII, CharacterSet.alphanumerics.contains(first) else { return false }
        return string.unicodeScalars.dropFirst().allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_")
        }
    }
}
