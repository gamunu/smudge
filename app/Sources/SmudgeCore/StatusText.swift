// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

/// Turns IPP printer-state-reasons keywords into plain language.
public enum StatusText {
    private static let known: [String: String] = [
        "media-empty": "Out of paper",
        "media-needed": "Paper needed",
        "media-jam": "Paper jam",
        "media-low": "Paper low",
        "marker-supply-low": "Ink low",
        "marker-supply-empty": "Out of ink",
        "marker-waste-almost-full": "Waste ink container almost full",
        "marker-waste-full": "Waste ink container full",
        "toner-low": "Ink low",
        "toner-empty": "Out of ink",
        "offline": "Printer offline or unplugged",
        "offline-report": "Printer offline or unplugged",
        "connecting-to-device": "Connecting to the printer",
        "cover-open": "Cover open",
        "door-open": "Door open",
        "input-tray-missing": "Paper tray missing",
        "output-area-full": "Output tray full",
        "output-area-almost-full": "Output tray almost full",
        "paused": "Printer paused",
        "shutdown": "Printer shutting down",
        "spool-area-full": "Spool area full",
        "cups-waiting-for-job-completed": "Waiting for job to finish",
        "other": "Unspecified printer condition",
    ]

    /// Returns nil for "none".
    public static func describe(_ reason: String) -> String? {
        if reason == "none" { return nil }
        if reason.hasPrefix("com.hp.") { return "Driver reported: \(reason)" }
        if let t = known[reason] { return t }
        for suffix in ["-error", "-warning", "-report"] where reason.hasSuffix(suffix) {
            let base = String(reason.dropLast(suffix.count))
            if let t = known[base] { return t }
        }
        return reason
    }

    public static func describe(all reasons: [String]) -> [String] {
        reasons.compactMap(describe)
    }

    /// True when a reason signals a problem rather than routine information.
    static func isProblem(_ reason: String) -> Bool {
        if reason == "none" || reason == "cups-waiting-for-job-completed" { return false }
        if reason.hasSuffix("-report") && reason != "offline-report" { return false }
        return true
    }
}
