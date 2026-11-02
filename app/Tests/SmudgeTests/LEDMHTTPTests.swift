// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import XCTest
@testable import Smudge
@testable import SmudgeKit

final class LEDMHTTPTests: XCTestCase {
    private let body = Fixture.calibrationState("CalibrationRequired")

    func testContentLengthReply() throws {
        let raw = Fixture.httpOK(body)
        let (resp, used) = try XCTUnwrap(LEDMHTTP.parse(raw))
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(resp.reason, "OK")
        XCTAssertEqual(resp.headers["content-type"], "text/xml")
        XCTAssertEqual(resp.text, body)
        XCTAssertEqual(used, raw.count)
    }

    func testContentLengthWaitsForFullBody() {
        let raw = Fixture.httpOK(body)
        XCTAssertNil(LEDMHTTP.parse(raw.dropLast()))
        XCTAssertNil(LEDMHTTP.parse(raw.prefix(20)))
        XCTAssertNil(LEDMHTTP.parse(Data()))
    }

    func testChunkedReply() throws {
        let raw = Fixture.httpChunked(Fixture.consumablesTwoCartridges, chunkSize: 97)
        let (resp, used) = try XCTUnwrap(LEDMHTTP.parse(raw))
        XCTAssertEqual(resp.text, Fixture.consumablesTwoCartridges)
        XCTAssertEqual(used, raw.count)
    }

    func testChunkedReplyIncompleteAtEveryCut() throws {
        let raw = Fixture.httpChunked(body, chunkSize: 40)
        for cut in 0..<raw.count {
            XCTAssertNil(LEDMHTTP.parse(raw.prefix(cut)), "cut at \(cut)")
        }
        XCTAssertNotNil(LEDMHTTP.parse(raw))
    }

    func testChunkedExtensionAndTrailers() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n0\r\nX-Trailer: a\r\n\r\n".utf8)
        let (resp, used) = try XCTUnwrap(LEDMHTTP.parse(raw))
        XCTAssertEqual(resp.text, "hello")
        XCTAssertEqual(used, raw.count)
    }

    func testBytesAfterTheReplyAreLeftAlone() throws {
        let first = Fixture.httpOK(body)
        let second = Fixture.httpOK("<b/>")
        let (_, used) = try XCTUnwrap(LEDMHTTP.parse(first + second))
        XCTAssertEqual(used, first.count)
    }

    func testJunkBeforeStatusLineIsFlagged() throws {
        let raw = Data("garbage\r\n\r\n".utf8)
        let (resp, used) = try XCTUnwrap(LEDMHTTP.parse(raw))
        XCTAssertEqual(resp.status, -1)
        XCTAssertEqual(used, raw.count)
    }

    func testNoFramingMeansEmptyBody() throws {
        let (resp, _) = try XCTUnwrap(LEDMHTTP.parse(Data("HTTP/1.1 404 Not Found\r\n\r\n".utf8)))
        XCTAssertEqual(resp.status, 404)
        XCTAssertEqual(resp.reason, "Not Found")
        XCTAssertTrue(resp.body.isEmpty)
    }

    func testRootElement() {
        XCTAssertEqual(LEDMHTTP.rootElement(Fixture.data(Fixture.consumablesTwoCartridges)), "ConsumableConfigDyn")
        XCTAssertEqual(LEDMHTTP.rootElement(Fixture.data(Fixture.productStatus(["ready"]))), "ProductStatusDyn")
        XCTAssertEqual(LEDMHTTP.rootElement(Fixture.data(body)), "CalibrationState")
        XCTAssertEqual(LEDMHTTP.rootElement(Fixture.data(Fixture.jobList())), "JobList")
        XCTAssertNil(LEDMHTTP.rootElement(Data("no markup".utf8)))
    }

    func testDefaultRoot() {
        XCTAssertEqual(LEDMClient.defaultRoot("/DevMgmt/ProductStatusDyn.xml"), "ProductStatusDyn")
        XCTAssertNil(LEDMClient.defaultRoot("/Jobs/JobList"))
        XCTAssertNil(LEDMClient.defaultRoot("/Calibration/State"))
    }

    // MARK: reply reader

    func testReplySplitAcrossReads() throws {
        let raw = Fixture.httpOK(Fixture.productStatus(["ready"]))
        var reader = LEDMReplyReader(expectRoot: "ProductStatusDyn")
        var got: LEDMResponse?
        let step = 53
        var i = 0
        while i < raw.count {
            let piece = raw[i..<min(i + step, raw.count)]
            let r = reader.feed(Data(piece))
            if i + step < raw.count { XCTAssertNil(r, "reply cannot be complete at \(i)") } else { got = r }
            i += step
        }
        XCTAssertEqual(got?.status, 200)
        XCTAssertEqual(LEDMHTTP.rootElement(got!.body), "ProductStatusDyn")
    }

    func testChunkedReplySplitAcrossReads() throws {
        let raw = Fixture.httpChunked(Fixture.productStatus(["ready"]), chunkSize: 64)
        var reader = LEDMReplyReader(expectRoot: "ProductStatusDyn")
        XCTAssertNil(reader.feed(raw.prefix(raw.count / 2)))
        let r = try XCTUnwrap(reader.feed(raw.suffix(from: raw.count / 2)))
        XCTAssertEqual(LEDMHTTP.rootElement(r.body), "ProductStatusDyn")
    }

    func testStalePreviousReplyIsSkipped() throws {
        // A late reply to an earlier request arrives first, then the real one in the same read.
        let stale = Fixture.httpOK(Fixture.consumablesTwoCartridges)
        let wanted = Fixture.httpOK(Fixture.productStatus(["processing"]))
        var logged: [String] = []
        var reader = LEDMReplyReader(expectRoot: "ProductStatusDyn") { logged.append($0) }
        let r = try XCTUnwrap(reader.feed(stale + wanted))
        XCTAssertEqual(LEDMHTTP.rootElement(r.body), "ProductStatusDyn")
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("ConsumableConfigDyn"))
    }

    func testStaleReplyAloneKeepsReading() throws {
        var reader = LEDMReplyReader(expectRoot: "ProductStatusDyn")
        XCTAssertNil(reader.feed(Fixture.httpOK(Fixture.consumablesTwoCartridges)))
        XCTAssertNotNil(reader.feed(Fixture.httpOK(Fixture.productStatus(["ready"]))))
    }

    func testRootMismatchOnlyAppliesTo200() throws {
        var reader = LEDMReplyReader(expectRoot: "ProductStatusDyn")
        let r = try XCTUnwrap(reader.feed(Data("HTTP/1.1 500 Server Error\r\nContent-Length: 0\r\n\r\n".utf8)))
        XCTAssertEqual(r.status, 500)
    }

    func testNoExpectedRootAcceptsAnyReply() throws {
        var reader = LEDMReplyReader(expectRoot: nil)
        XCTAssertNotNil(reader.feed(Fixture.httpOK(Fixture.consumablesTwoCartridges)))
    }

    func testContinueIsSkipped() throws {
        var reader = LEDMReplyReader(expectRoot: nil)
        let cont = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
        let r = try XCTUnwrap(reader.feed(cont + Fixture.httpOK("<a/>")))
        XCTAssertEqual(r.status, 200)
    }

    // MARK: requests

    func testGetRequest() {
        let s = String(decoding: LEDMHTTP.getRequest("/DevMgmt/ProductStatusDyn.xml"), as: UTF8.self)
        XCTAssertTrue(s.hasPrefix("GET /DevMgmt/ProductStatusDyn.xml HTTP/1.1\r\n"))
        XCTAssertTrue(s.hasSuffix("\r\n\r\n"))
    }

    func testCancelRequestBody() throws {
        let req = LEDMHTTP.putRequest("/Jobs/JobList/17", xml: Maintenance.cancelJobXML)
        let text = String(decoding: req, as: UTF8.self)
        let parts = text.components(separatedBy: "\r\n\r\n")
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[0].hasPrefix("PUT /Jobs/JobList/17 HTTP/1.1\r\n"))
        XCTAssertTrue(parts[0].contains("Content-Type: text/xml"))
        XCTAssertTrue(parts[0].contains("Content-Length: \(Data(parts[1].utf8).count)"))
        // The body is well formed and sets JobState to Canceled.
        let root = try XCTUnwrap(parseXML(Data(parts[1].utf8)))
        XCTAssertEqual(root.name, "Job")
        XCTAssertEqual(root.value("JobState"), "Canceled")
    }

    func testPostRequestsCarryTheBody() {
        let xml = Maintenance.jobXML("cleaningPage")
        for req in [LEDMHTTP.postRequest("/DevMgmt/InternalPrintDyn.xml", xml: xml),
                    LEDMHTTP.postFooterRequest("/Calibration/Session", xml: xml)] {
            let text = String(decoding: req, as: UTF8.self)
            XCTAssertTrue(text.hasPrefix("POST "))
            XCTAssertTrue(text.hasSuffix(xml))
            XCTAssertTrue(text.lowercased().contains("content-length: \(Data(xml.utf8).count)")
                          || text.lowercased().contains("content-length:\(Data(xml.utf8).count)"))
        }
    }
}
