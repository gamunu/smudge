// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import XCTest
@testable import SmudgeCore
@testable import SmudgeKit

final class MaintenanceTests: XCTestCase {
    // MARK: status categories

    func testStatusCategories() {
        func cats(_ c: [String]) -> [String] { Maintenance.statusCategories(Fixture.data(Fixture.productStatus(c))) }
        XCTAssertEqual(cats(["genuineHP", "ready"]), ["genuineHP", "ready"])
        XCTAssertEqual(cats(["genuineHP", "processing"]), ["genuineHP", "processing"])
        XCTAssertEqual(cats(["genuineHP", "calibrating"]), ["genuineHP", "calibrating"])
        XCTAssertEqual(cats(["trayEmptyOrOpen"]), ["trayEmptyOrOpen"])
        XCTAssertEqual(cats(["closeDoorOrCover"]), ["closeDoorOrCover"])
        XCTAssertEqual(Maintenance.statusCategories(Data("junk".utf8)), [])
    }

    func testBusyRule() {
        XCTAssertFalse(Maintenance.isBusy(["genuineHP", "ready"]))
        XCTAssertFalse(Maintenance.isBusy(["genuineHP", "inPowerSave"]))
        XCTAssertFalse(Maintenance.isBusy(["trayEmptyOrOpen"]))
        XCTAssertFalse(Maintenance.isBusy(["closeDoorOrCover"]))
        XCTAssertTrue(Maintenance.isBusy(["genuineHP", "processing"]))
        XCTAssertTrue(Maintenance.isBusy(["calibrating"]))
        XCTAssertTrue(Maintenance.isBusy(["cleaning"]))
        XCTAssertFalse(Maintenance.isBusy([]))
    }

    func testAttention() {
        XCTAssertNil(Maintenance.attention(["genuineHP", "ready"]))
        XCTAssertNil(Maintenance.attention(["processing"]))
        XCTAssertEqual(Maintenance.attention(["trayEmptyOrOpen"]), .loadPaper)
        XCTAssertEqual(Maintenance.attention(["genuineHP", "closeDoorOrCover"]), .closeDoor)
        XCTAssertEqual(Maintenance.attention(["paperJam"]), .other("paperJam"))
        XCTAssertEqual(Maintenance.attention(["inkEmpty"]), .other("inkEmpty"))
    }

    func testAttentionText() {
        XCTAssertEqual(Attention.loadPaper.title, "Put paper in the printer")
        XCTAssertEqual(Attention.closeDoor.title, "Close the front door")
        XCTAssertEqual(Attention.other("x").title, "x")
    }

    func testLiveText() {
        XCTAssertEqual(Maintenance.liveText(["genuineHP", "ready"]), "Ready")
        XCTAssertEqual(Maintenance.liveText(["genuineHP", "processing"]), "Printing")
        XCTAssertEqual(Maintenance.liveText(["calibrating"]), "Aligning")
        XCTAssertEqual(Maintenance.liveText(["trayEmptyOrOpen"]), "Paper tray empty or open")
        XCTAssertEqual(Maintenance.liveText(["closeDoorOrCover"]), "Door or cover open")
        XCTAssertEqual(Maintenance.liveText(["genuineHP"]), "Ready")
        XCTAssertEqual(Maintenance.liveText([]), "Waiting for the printer")
        XCTAssertEqual(Maintenance.liveText(["somethingNew"]), "somethingNew")
    }

    // MARK: job list

    func testJobListWithCanceledCalibrationJob() {
        let jobs = Maintenance.parseJobList(Fixture.data(Fixture.jobList()))
        XCTAssertEqual(jobs.map(\.url), ["/Jobs/JobList/1", "/Jobs/JobList/2", "/Jobs/JobList/3", "/Jobs/JobList/4"])
        XCTAssertEqual(jobs.map(\.state), ["Completed", "Completed", "Canceled", "Completed"])
        XCTAssertEqual(jobs[2].category, "Calibration")
        XCTAssertEqual(jobs[2].calibrationState, "CalibrationRequired")
        XCTAssertNil(jobs[0].calibrationState)
        XCTAssertTrue(jobs.allSatisfy { !$0.isActive })
    }

    func testActiveJobsAreTheUnfinishedOnes() {
        let xml = Fixture.jobList(extraJob: ("Calibration", "Processing"))
        let active = Maintenance.parseJobList(Fixture.data(xml)).filter(\.isActive)
        XCTAssertEqual(active.map(\.url), ["/Jobs/JobList/5"])
        for state in ["Pending", "Paused", "Processing"] {
            XCTAssertTrue(LEDMJob(url: "/x", category: "Print", state: state, calibrationState: nil).isActive, state)
        }
        for state in ["Completed", "Canceled", "Cancelled", "completed", ""] {
            XCTAssertFalse(LEDMJob(url: "/x", category: "Print", state: state, calibrationState: nil).isActive, state)
        }
    }

    func testJobListIgnoresJobsWithoutUrl() {
        let xml = "<j:JobList xmlns:j=\"urn:x\"><j:Job><j:JobState>Completed</j:JobState></j:Job></j:JobList>"
        XCTAssertTrue(Maintenance.parseJobList(Fixture.data(xml)).isEmpty)
    }

    // MARK: internal print jobs

    func testSupportedJobTypes() {
        XCTAssertEqual(Maintenance.supportedJobTypes(Fixture.data(Fixture.internalPrintCap)),
                       ["cleaningPage", "cleaningPageLevel2", "diagnosticsPage", "paperFeedCleaningPage", "ribSmearCleaningPage"])
    }

    func testJobXMLNamesTheJobType() throws {
        for type in ["cleaningPage", "cleaningPageLevel2", "diagnosticsPage", "paperFeedCleaningPage", "ribSmearCleaningPage"] {
            let root = try XCTUnwrap(parseXML(Fixture.data(Maintenance.jobXML(type))))
            XCTAssertEqual(root.name, "InternalPrintCap")
            XCTAssertEqual(root.value("JobType"), type)
        }
    }

    func testCancelBody() throws {
        let root = try XCTUnwrap(parseXML(Fixture.data(Maintenance.cancelJobXML)))
        XCTAssertEqual(root.name, "Job")
        XCTAssertEqual(root.value("JobState"), "Canceled")
    }

    // MARK: calibration

    func testCalibrationWord() {
        for w in ["CalibrationRequired", "Printing", "ScanRequested", "Scanning", "CalibrationValid", "ParmsRequested"] {
            XCTAssertEqual(Maintenance.calibrationWord(Fixture.calibrationState(w)), w)
        }
        XCTAssertNil(Maintenance.calibrationWord("<a/>"))
    }

    func testCalibrationPrintingBody() throws {
        let root = try XCTUnwrap(parseXML(Fixture.data(Maintenance.calibrationPrintingXML)))
        XCTAssertEqual(root.name, "CalibrationState")
        XCTAssertEqual(root.text, "Printing")
    }

    // MARK: cancel result text

    func testCancelResultSummary() {
        var r = CancelResult()
        r.found = 0
        r.finalCategories = ["ready"]
        XCTAssertEqual(r.lines, ["The printer has no active job to cancel.", "Printer status: Ready."])

        r = CancelResult()
        r.found = 1
        r.puts = [("/Jobs/JobList/5", 200)]
        r.finalCategories = ["ready"]
        XCTAssertEqual(r.lines.first, "Cancelled 1 of 1 active job.")
        XCTAssertFalse(r.stillRunning)

        r.finalCategories = ["calibrating"]
        XCTAssertTrue(r.stillRunning)

        r = CancelResult()
        r.error = "timeout"
        XCTAssertEqual(r.lines.first, "The printer did not answer, so nothing was cancelled.")
    }

    // MARK: StatusText

    func testStatusTextReasons() {
        XCTAssertNil(StatusText.describe("none"))
        XCTAssertEqual(StatusText.describe("media-empty"), "Out of paper")
        XCTAssertEqual(StatusText.describe("media-empty-error"), "Out of paper")
        XCTAssertEqual(StatusText.describe("marker-supply-low-warning"), "Ink low")
        XCTAssertEqual(StatusText.describe("offline-report"), "Printer offline or unplugged")
        XCTAssertEqual(StatusText.describe("com.hp.foo"), "Driver reported: com.hp.foo")
        XCTAssertEqual(StatusText.describe("something-else"), "something-else")
        XCTAssertEqual(StatusText.describe(all: ["none", "media-jam", "toner-low"]), ["Paper jam", "Ink low"])
    }

    func testStatusTextProblems() {
        XCTAssertFalse(StatusText.isProblem("none"))
        XCTAssertFalse(StatusText.isProblem("cups-waiting-for-job-completed"))
        XCTAssertFalse(StatusText.isProblem("marker-supply-low-report"))
        XCTAssertTrue(StatusText.isProblem("offline-report"))
        XCTAssertTrue(StatusText.isProblem("media-empty-error"))
    }
}
