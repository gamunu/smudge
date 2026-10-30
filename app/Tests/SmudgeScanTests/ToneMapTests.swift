// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import XCTest
@testable import SmudgeScan

final class ToneMapTests: XCTestCase {
    func testToneNeutralAndEnds() {
        let t = ToneCalibration(neutral: 1000, min: 0, max: 2000, deviceApplies: true)
        XCTAssertEqual(t.device(nil), 1000); XCTAssertEqual(t.device(1000), 1000)
        XCTAssertEqual(t.device(0), 0); XCTAssertEqual(t.device(2000), 2000)
    }

    func testToneIsLinearOnEachSideOfNeutral() {
        let t = ToneCalibration(neutral: 800, min: 0, max: 2000, deviceApplies: true)
        XCTAssertEqual(t.device(500), 400)
        XCTAssertEqual(t.device(1500), 1400)
        XCTAssertEqual(t.device(5000), 2000)   // out of range is clamped
        XCTAssertEqual(t.device(-5), 0)
    }
}
