// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import XCTest
@testable import SmudgeScan

final class LEDMScanCapsTests: XCTestCase {
    func testParses2336Caps() throws {
        let c = try XCTUnwrap(LEDMScanCaps.parse(Data(ScanFixtures.scanCaps2336.utf8)))
        XCTAssertEqual(c.model, "DeskJet Ink Advantage 2300 All-in-One Printer series")
        XCTAssertEqual([c.minWidth, c.minHeight, c.maxWidth, c.maxHeight], [8, 8, 2550, 3508])
        XCTAssertEqual(c.resolutions, [75, 100, 200, 300, 600, 1200])
        XCTAssertEqual(c.maxOptical, 1200)
        XCTAssertEqual(c.formats[.color8], [.raw, .jpeg])
        XCTAssertEqual(c.formats[.k1], [.raw])
        XCTAssertFalse(c.hasADF)
    }

    func testAdfSectionSetsFlagAndIsOtherwiseIgnored() throws {
        let xml = ScanFixtures.scanCaps2336.replacingOccurrences(of: "</ScanCaps>", with: """
        <Adf><InputSourceCaps><MaxWidth>9999</MaxWidth></InputSourceCaps></Adf></ScanCaps>
        """)
        let c = try XCTUnwrap(LEDMScanCaps.parse(Data(xml.utf8)))
        XCTAssertTrue(c.hasADF)
        XCTAssertEqual(c.maxWidth, 2550)
    }

    func testJunkIsNil() {
        XCTAssertNil(LEDMScanCaps.parse(Data("<nope/>".utf8)))
    }
}
