// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import XCTest
@testable import SmudgeScan
import SmudgeKit

final class LEDMScanJobTests: XCTestCase {
    func testScanRequestXMLFieldOrderAndValues() {
        let r = LEDMScanRequest(resolution: 300, xStart: 0, yStart: 0, width: 2480, height: 3508,
                                format: .jpeg, colorSpace: "Color", brightness: 1000, contrast: 1000)
        let names = ["XResolution", "YResolution", "XStart", "Width", "YStart", "Height", "Format", "CompressionQFactor",
                     "ColorSpace", "BitDepth", "InputSource", "InputSourceType", "GrayRendering", "ToneMap", "ContentType"]
        let positions = names.map { r.xml.range(of: "<\($0)>")!.lowerBound }
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertTrue(r.xml.contains("<ScanSettings xmlns=\"http://www.hp.com/schemas/imaging/con/cnx/scan/2008/08/19\">"))
        XCTAssertTrue(r.xml.contains("<Width>2480</Width>"))
        XCTAssertTrue(r.xml.contains("<InputSource>Platen</InputSource>"))
        XCTAssertTrue(r.xml.contains("<Brightness>1000</Brightness>"))
    }

    func testJobSnapshotReadyToUpload() {
        let s = LEDMJobSnapshot.parse(Data(ScanFixtures.jobReadyToUpload2336.utf8))
        XCTAssertEqual(s.jobState, "Processing"); XCTAssertEqual(s.pageState, "ReadyToUpload")
        XCTAssertEqual(s.binaryURL, "/Scan/Jobs/14/Pages/1"); XCTAssertTrue(s.hasPreScanPage)
        XCTAssertEqual(LEDMJobStep.next(s), .upload("/Scan/Jobs/14/Pages/1"))
        XCTAssertEqual(s.imageWidth, 637); XCTAssertEqual(s.imageHeight, 877); XCTAssertEqual(s.bytesPerLine, 1911)
        XCTAssertEqual(s.geometry, PageGeometry(width: 637, height: 877, bytesPerLine: 1911))
    }

    func testJobSnapshotWithoutPageHasNoPreScanPage() {
        let xml = "<j:Job xmlns:j=\"x\"><j:JobState>Completed</j:JobState></j:Job>"
        let s = LEDMJobSnapshot.parse(Data(xml.utf8))
        XCTAssertFalse(s.hasPreScanPage); XCTAssertNil(s.pageState); XCTAssertNil(s.geometry)
    }

    func testScannerState() {
        let xml = "<ScanStatus xmlns=\"x\"><ScannerState>Idle</ScannerState></ScanStatus>"
        XCTAssertEqual(LEDMScanStatus.scannerState(Data(xml.utf8)), "Idle")
    }

    func testRequestBuilders() {
        let post = String(decoding: LEDMHTTP.scanPostRequest(xml: "<a/>"), as: UTF8.self)
        XCTAssertTrue(post.hasPrefix("POST /Scan/Jobs HTTP/1.1\r\nHost: localhost\r\n"))
        XCTAssertTrue(post.contains("User-Agent: hplip"))
        XCTAssertTrue(post.contains("Content-Type: */*"))
        let get = String(decoding: LEDMHTTP.scanGetRequest("/Scan/Jobs/1"), as: UTF8.self)
        XCTAssertTrue(get.hasPrefix("GET /Scan/Jobs/1 HTTP/1.1\r\nHost: localhost\r\n"))
        let cancel = String(decoding: LEDMHTTP.scanCancelRequest("/Scan/Jobs/1", xml: LEDMScanJob.cancelXML), as: UTF8.self)
        XCTAssertTrue(cancel.hasPrefix("PUT /Scan/Jobs/1 HTTP/1.1\r\n"))
        XCTAssertTrue(cancel.contains("Cookie: AccessCounter=new"))
        XCTAssertTrue(cancel.contains("<j:JobState>Canceled</j:JobState>"))
    }

    func testJobWithoutPageKeepsWaiting() {
        // The first job reply after the POST has no page yet. Ending the job there left the printer scanning.
        let s = LEDMJobSnapshot.parse(Data("<j:Job xmlns:j=\"x\"><j:JobState>Processing</j:JobState></j:Job>".utf8))
        XCTAssertEqual(LEDMJobStep.next(s), .wait)
    }

    func testJobStepEnds() {
        XCTAssertEqual(LEDMJobStep.next(LEDMJobSnapshot(pageState: "ReadyToUpload", binaryURL: "/Scan/Jobs/3/Pages/1")), .upload("/Scan/Jobs/3/Pages/1"))
        XCTAssertEqual(LEDMJobStep.next(LEDMJobSnapshot(pageState: "ReadyToUpload")), .wait)
        XCTAssertEqual(LEDMJobStep.next(LEDMJobSnapshot(pageState: "CanceledByDevice")), .finished(.canceledByDevice))
        XCTAssertEqual(LEDMJobStep.next(LEDMJobSnapshot(jobState: "Completed", pageState: "UploadCompleted")), .finished(.noDocument))
        XCTAssertEqual(LEDMJobStep.next(LEDMJobSnapshot(jobState: "Canceled")), .finished(.canceledByDevice))
    }
}
