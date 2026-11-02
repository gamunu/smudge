// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

/// Decides what an alignment run is doing from the polled printer state. It holds
/// no timers and reads no clock of its own: the caller passes the current time,
/// so tests can drive it step by step.
///
/// Sequence seen on a DeskJet 2300 over USB:
/// CalibrationRequired -> Printing (calibrating) -> ScanRequested -> Scanning -> CalibrationRequired + ready.
/// The printer does not report CalibrationValid after a good alignment, so success is
/// "passed through Scanning, then ready with nothing to fix". CalibrationValid also counts.
struct AlignTracker {
    enum Step: Equatable {
        case keepGoing
        case done
        case failed(String)
    }

    static let hardTimeout: TimeInterval = 900     // the page was never scanned
    static let startTimeout: TimeInterval = 60     // the printer never left its starting state
    static let maxFailures = 10                    // polls in a row with no answer at all
    static let settledWithoutScan = 10             // ready polls before "scan not detected"

    let started: Date
    private(set) var stage: FlowStage = .running
    private(set) var reached = 1
    private(set) var categories: [String] = []
    private(set) var calState: String?
    private(set) var attention: Attention?

    private var left = false          // state moved off the starting point
    private var sawScan = false
    private var settled = 0           // consecutive polls that look ready
    private var failures = 0

    init(started: Date) { self.started = started }

    /// Run before reading the printer. Returns a failure when the run took too long.
    mutating func checkTimeout(now: Date) -> Step {
        let elapsed = now.timeIntervalSince(started)
        if elapsed > Self.hardTimeout {
            return .failed("The scan was not detected. The page was never scanned within 15 minutes.")
        }
        if !left && elapsed > Self.startTimeout {
            return .failed("The printer did not start printing the alignment page.")
        }
        return .keepGoing
    }

    /// Feed one poll. `cats` is the ProductStatusDyn categories and `cal` the
    /// /Calibration/State word, nil when that read failed.
    mutating func observe(cats: [String]?, cal: String?) -> Step {
        if cats == nil && cal == nil {
            failures += 1
            return failures >= Self.maxFailures ? .failed("The printer stopped answering.") : .keepGoing
        }
        failures = 0
        if let c = cats { categories = c; attention = Maintenance.attention(c) }
        if let w = cal { calState = w }
        let word = cal ?? calState

        switch word {
        case "ScanRequested":
            left = true
            stage = .awaitScan
            reached = 2
        case "Scanning":
            left = true
            sawScan = true
            stage = .scanning
            reached = 2
        case "Printing", "ParmsRequested":
            left = true
        case "CalibrationValid":
            if left || sawScan { return finish() }
        default: break
        }
        let busy = cats.map(Maintenance.isBusy) ?? true
        if busy && cats != nil { left = true }
        let ready = cats != nil && !busy && attention == nil
            && (word == "CalibrationRequired" || word == "CalibrationValid")
        settled = ready ? settled + 1 : 0
        if sawScan && settled >= 1 { return finish() }
        if left && !sawScan && settled >= Self.settledWithoutScan {
            return .failed("The printer went back to ready without scanning the page. The scan was not detected.")
        }
        return .keepGoing
    }

    private mutating func finish() -> Step {
        stage = .done
        reached = 3
        return .done
    }
}
