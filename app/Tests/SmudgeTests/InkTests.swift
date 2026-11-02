// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import XCTest
@testable import SmudgeCore

final class InkTests: XCTestCase {
    func testTwoCartridgesFromRealShape() throws {
        let report = try XCTUnwrap(InkParser.parse(Fixture.data(Fixture.consumablesTwoCartridges)))
        XCTAssertEqual(report.cartridges.map(\.label), ["CMY", "K"])
        XCTAssertEqual(report.cartridges.map(\.percent), [90, 100])
        XCTAssertEqual(report.cartridges.map(\.state), [.ok, .ok])
        XCTAssertEqual(report.cartridges.map(\.rawState), ["newGenuineHP", "newGenuineHP"])
        XCTAssertEqual(report.cartridges.map(\.product), ["682", "682"])
        XCTAssertEqual(report.cartridges.map(\.name), ["Tri-color", "Black"])
        XCTAssertEqual(report.alignmentMode, "semiAutomatic")
    }

    func testSupportedConsumablesBlockIsNotACartridge() throws {
        // The ProductConsumableInfo block lists CMY too, but only ConsumableInfo counts.
        let report = try XCTUnwrap(InkParser.parse(Fixture.data(Fixture.consumablesTwoCartridges)))
        XCTAssertEqual(report.cartridges.count, 2)
    }

    func testWrongRootIsRejected() {
        XCTAssertNil(InkParser.parse(Fixture.data(Fixture.productStatus(["ready"]))))
        XCTAssertNil(InkParser.parse(Data("not xml".utf8)))
    }

    private func state(_ raw: String = "newGenuineHP", measured: String = "ok", percent: Int?, brand: String = "HP",
                       refilled: Bool = false) throws -> (InkState, Int?) {
        let xml = Fixture.consumableConfig([Fixture.ink(label: "K", state: raw, measured: measured, brand: brand,
                                                        refilled: refilled, percent: percent)])
        let c = try XCTUnwrap(InkParser.parse(Fixture.data(xml))?.cartridges.first)
        return (c.state, c.percent)
    }

    func testOk() throws {
        XCTAssertEqual(try state(percent: 90).0, .ok)
        XCTAssertEqual(try state("genuineHP", percent: 40).0, .ok)
        XCTAssertEqual(try state(percent: 11).0, .ok)
    }

    func testLowByPercentAndByState() throws {
        XCTAssertEqual(try state(percent: 10).0, .low)
        XCTAssertEqual(try state(percent: 6).0, .low)
        XCTAssertEqual(try state("low", percent: 50).0, .low)
    }

    func testVeryLowByPercentAndByState() throws {
        XCTAssertEqual(try state(percent: 5).0, .veryLow)
        XCTAssertEqual(try state(percent: 1).0, .veryLow)
        XCTAssertEqual(try state("veryLow", percent: 30).0, .veryLow)
    }

    func testEmpty() throws {
        XCTAssertEqual(try state(percent: 0).0, .empty)
        XCTAssertEqual(try state("empty", percent: 20).0, .empty)
    }

    func testZeroPercentWithUnknownMeasurementIsUnknown() throws {
        XCTAssertEqual(try state(measured: "unknown", percent: 0).0, .unknown)
    }

    func testMissing() throws {
        XCTAssertEqual(try state("missing", percent: nil).0, .missing)
        XCTAssertEqual(try state("misinstalled", percent: 90).0, .missing)
    }

    func testUnknownAndMissingPercent() throws {
        let (s, p) = try state("unknown", percent: nil)
        XCTAssertEqual(s, .unknown)
        XCTAssertNil(p)
        // A reported state with no percent stays what the printer said, never an estimate.
        let (s2, p2) = try state(percent: nil)
        XCTAssertEqual(s2, .ok)
        XCTAssertNil(p2)
    }

    func testNonHPAndRefilled() throws {
        XCTAssertEqual(try state(percent: 80, brand: "Acme").0, .nonHP)
        XCTAssertEqual(try state(percent: 80, refilled: true).0, .nonHP)
        XCTAssertEqual(try state("nonHP", percent: 80).0, .nonHP)
    }

    func testPercentIsClamped() throws {
        XCTAssertEqual(try state(percent: 140).1, 100)
    }

    func testNeedsAttention() {
        XCTAssertEqual([InkState.ok, .low, .veryLow, .empty, .missing, .nonHP, .unknown].filter(\.needsAttention), [.low, .veryLow, .empty, .missing])
    }

    func testMaintenanceJobTypes() {
        XCTAssertEqual(MaintenanceJob.clean.jobType, "cleaningPage")
        XCTAssertEqual(MaintenanceJob.deepClean.jobType, "cleaningPageLevel2")
        XCTAssertEqual(MaintenanceJob.diagnostics.jobType, "diagnosticsPage")
        XCTAssertNil(MaintenanceJob.align.jobType)
    }
}
