// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import XCTest
@testable import SmudgeCore

/// Drives the alignment state machine with a fake clock and the sequence the
/// printer really reports.
final class AlignTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let ready = ["genuineHP", "ready"]
    private let calibrating = ["genuineHP", "calibrating"]

    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testSuccessThroughScanningThenReady() {
        var t = AlignTracker(started: t0)
        XCTAssertEqual(t.observe(cats: calibrating, cal: "Printing"), .keepGoing)
        XCTAssertEqual(t.stage, .running)
        XCTAssertEqual(t.observe(cats: ["genuineHP", "ready"], cal: "ScanRequested"), .keepGoing)
        XCTAssertEqual(t.stage, .awaitScan)
        XCTAssertEqual(t.reached, 2)
        XCTAssertEqual(t.observe(cats: ["processing"], cal: "Scanning"), .keepGoing)
        XCTAssertEqual(t.stage, .scanning)
        // Back to CalibrationRequired and ready after the scan: the printer never says CalibrationValid.
        XCTAssertEqual(t.observe(cats: ready, cal: "CalibrationRequired"), .done)
        XCTAssertEqual(t.stage, .done)
        XCTAssertEqual(t.reached, 3)
    }

    func testStillBusyAfterScanDoesNotFinish() {
        var t = AlignTracker(started: t0)
        _ = t.observe(cats: calibrating, cal: "Scanning")
        XCTAssertEqual(t.observe(cats: calibrating, cal: "CalibrationRequired"), .keepGoing)
        XCTAssertEqual(t.observe(cats: ready, cal: "CalibrationRequired"), .done)
    }

    func testAttentionAfterScanBlocksFinish() {
        var t = AlignTracker(started: t0)
        _ = t.observe(cats: calibrating, cal: "Scanning")
        XCTAssertEqual(t.observe(cats: ["trayEmptyOrOpen"], cal: "CalibrationRequired"), .keepGoing)
        XCTAssertEqual(t.attention, .loadPaper)
        XCTAssertEqual(t.observe(cats: ready, cal: "CalibrationRequired"), .done)
    }

    func testCalibrationValidAfterLeavingStartCounts() {
        var t = AlignTracker(started: t0)
        XCTAssertEqual(t.observe(cats: calibrating, cal: "Printing"), .keepGoing)
        XCTAssertEqual(t.observe(cats: ready, cal: "CalibrationValid"), .done)
    }

    func testCalibrationValidAtTheStartIsIgnored() {
        var t = AlignTracker(started: t0)
        XCTAssertEqual(t.observe(cats: ready, cal: "CalibrationValid"), .keepGoing)
    }

    func testReadyWithoutScanFailsAfterTenQuietPolls() {
        var t = AlignTracker(started: t0)
        _ = t.observe(cats: calibrating, cal: "Printing")
        for i in 1..<10 {
            XCTAssertEqual(t.observe(cats: ready, cal: "CalibrationRequired"), .keepGoing, "poll \(i)")
        }
        guard case .failed(let m) = t.observe(cats: ready, cal: "CalibrationRequired") else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(m.contains("scan was not detected"))
    }

    func testBusyPollResetsTheQuietCount() {
        var t = AlignTracker(started: t0)
        _ = t.observe(cats: calibrating, cal: "Printing")
        for _ in 0..<9 { _ = t.observe(cats: ready, cal: "CalibrationRequired") }
        XCTAssertEqual(t.observe(cats: calibrating, cal: "CalibrationRequired"), .keepGoing)
        for _ in 0..<9 { XCTAssertEqual(t.observe(cats: ready, cal: "CalibrationRequired"), .keepGoing) }
    }

    func testPrinterNeverStartsFailsAfterSixtySeconds() {
        var t = AlignTracker(started: t0)
        XCTAssertEqual(t.checkTimeout(now: at(60)), .keepGoing)
        guard case .failed(let m) = t.checkTimeout(now: at(61)) else { return XCTFail("expected a failure") }
        XCTAssertTrue(m.contains("did not start printing"))
    }

    func testStartedRunIsNotCutOffAtSixtySeconds() {
        var t = AlignTracker(started: t0)
        _ = t.observe(cats: calibrating, cal: "Printing")
        XCTAssertEqual(t.checkTimeout(now: at(300)), .keepGoing)
    }

    func testNoScanWithinFifteenMinutesFails() {
        var t = AlignTracker(started: t0)
        _ = t.observe(cats: ready, cal: "ScanRequested")
        XCTAssertEqual(t.checkTimeout(now: at(900)), .keepGoing)
        guard case .failed(let m) = t.checkTimeout(now: at(901)) else { return XCTFail("expected a failure") }
        XCTAssertTrue(m.contains("never scanned"))
    }

    func testTenSilentPollsFail() {
        var t = AlignTracker(started: t0)
        for i in 1..<10 { XCTAssertEqual(t.observe(cats: nil, cal: nil), .keepGoing, "poll \(i)") }
        XCTAssertEqual(t.observe(cats: nil, cal: nil), .failed("The printer stopped answering."))
    }

    func testAnswerResetsTheSilenceCount() {
        var t = AlignTracker(started: t0)
        for _ in 0..<9 { _ = t.observe(cats: nil, cal: nil) }
        _ = t.observe(cats: calibrating, cal: nil)
        for _ in 0..<9 { XCTAssertEqual(t.observe(cats: nil, cal: nil), .keepGoing) }
    }

    func testMissingCalibrationReadKeepsLastWord() {
        var t = AlignTracker(started: t0)
        _ = t.observe(cats: ready, cal: "Scanning")
        XCTAssertEqual(t.calState, "Scanning")
        // The next poll lost the calibration read but the printer is ready: still counts as after the scan.
        XCTAssertEqual(t.observe(cats: ready, cal: nil), .keepGoing)   // word Scanning is not CalibrationRequired
        XCTAssertEqual(t.calState, "Scanning")
    }
}
