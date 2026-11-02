// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import XCTest
@testable import SmudgeCore

final class StuckQueueTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testStuckAfterTenSecondsOfProcessingWithNoJob() {
        var rule = StuckQueueRule()
        XCTAssertFalse(rule.update(stateCode: 4, hasActiveJob: false, printerBusy: false, now: at(0)))
        XCTAssertFalse(rule.update(stateCode: 4, hasActiveJob: false, printerBusy: false, now: at(10)))
        XCTAssertTrue(rule.update(stateCode: 4, hasActiveJob: false, printerBusy: false, now: at(11)))
    }

    func testActiveJobMeansNotStuck() {
        var rule = StuckQueueRule()
        _ = rule.update(stateCode: 4, hasActiveJob: false, printerBusy: false, now: at(0))
        XCTAssertFalse(rule.update(stateCode: 4, hasActiveJob: true, printerBusy: false, now: at(30)))
        // The clock restarts when the job is gone again.
        XCTAssertFalse(rule.update(stateCode: 4, hasActiveJob: false, printerBusy: false, now: at(31)))
        XCTAssertTrue(rule.update(stateCode: 4, hasActiveJob: false, printerBusy: false, now: at(42)))
    }

    func testPrinterReportingActivityMeansNotStuck() {
        var rule = StuckQueueRule()
        _ = rule.update(stateCode: 4, hasActiveJob: false, printerBusy: false, now: at(0))
        XCTAssertFalse(rule.update(stateCode: 4, hasActiveJob: false, printerBusy: true, now: at(60)))
        XCTAssertTrue(rule.update(stateCode: 4, hasActiveJob: false, printerBusy: false, now: at(61)))
    }

    func testIdleOrStoppedIsNeverStuck() {
        var rule = StuckQueueRule()
        for code in [3, 5, 0] {
            XCTAssertFalse(rule.update(stateCode: code, hasActiveJob: false, printerBusy: false, now: at(0)))
            XCTAssertFalse(rule.update(stateCode: code, hasActiveJob: false, printerBusy: false, now: at(100)))
        }
        XCTAssertFalse(rule.update(stateCode: nil, hasActiveJob: false, printerBusy: false, now: at(200)))
    }

    func testLeavingProcessingClearsTheClock() {
        var rule = StuckQueueRule()
        _ = rule.update(stateCode: 4, hasActiveJob: false, printerBusy: false, now: at(0))
        XCTAssertFalse(rule.update(stateCode: 3, hasActiveJob: false, printerBusy: false, now: at(20)))
        XCTAssertFalse(rule.update(stateCode: 4, hasActiveJob: false, printerBusy: false, now: at(21)))
    }
}
