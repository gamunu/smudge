// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import XCTest
@testable import SmudgeCore
@testable import SmudgeKit

final class LEDMClientTests: XCTestCase {
    private let status = Fixture.productStatus(["ready"])

    /// A client whose every open hands out the next fake; the last one repeats.
    private func client(_ fakes: [FakeTransport], channel: LEDMChannel = .management,
                        timeout: TimeInterval = 0.2) -> (LEDMClient, () -> Int) {
        var opened = 0
        let c = LEDMClient(serial: "CN123", channel: channel) { serial, ch in
            XCTAssertEqual(serial, "CN123")
            let f = fakes[min(opened, fakes.count - 1)]
            opened += 1
            return f
        }
        c.overallTimeout = timeout
        return (c, { opened })
    }

    // MARK: requests

    func testGetFramesRequestAndParsesReply() throws {
        let fake = FakeTransport(reply: Fixture.httpOK(status))
        let (c, _) = client([fake])
        let r = try c.get("/DevMgmt/ProductStatusDyn.xml")
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.text, status)
        XCTAssertEqual(fake.written, [LEDMHTTP.getRequest("/DevMgmt/ProductStatusDyn.xml")])
        XCTAssertEqual(fake.drained, 1)
    }

    func testPutPostAndPostFooterSendTheirFormats() throws {
        let xml = Maintenance.jobXML("cleaningPage")
        let ok = Fixture.httpOK("<a/>")
        let cases: [(LEDMClient) throws -> LEDMResponse] = [
            { try $0.put("/Calibration/Data", xml: xml) },
            { try $0.post("/DevMgmt/InternalPrintDyn.xml", xml: xml) },
            { try $0.postFooter("/Calibration/Session", xml: xml) },
        ]
        let wire = [LEDMHTTP.putRequest("/Calibration/Data", xml: xml),
                    LEDMHTTP.postRequest("/DevMgmt/InternalPrintDyn.xml", xml: xml),
                    LEDMHTTP.postFooterRequest("/Calibration/Session", xml: xml)]
        for (call, expected) in zip(cases, wire) {
            let fake = FakeTransport(reply: ok)
            let (c, _) = client([fake])
            XCTAssertEqual(try call(c).status, 200)
            XCTAssertEqual(fake.written, [expected])
        }
    }

    func testReplySplitAtEveryByteBoundary() throws {
        for raw in [Fixture.httpOK(status), Fixture.httpChunked(status, chunkSize: 37)] {
            for cut in 1..<raw.count {
                let fake = FakeTransport(replies: [.data(raw.prefix(cut)), .data(raw.dropFirst(cut))])
                let (c, _) = client([fake])
                XCTAssertEqual(try c.get("/DevMgmt/ProductStatusDyn.xml").text, status, "cut \(cut)")
            }
        }
    }

    func testReplyOneByteAtATime() throws {
        let fake = FakeTransport(reply: Fixture.httpChunked(status, chunkSize: 50), chunk: 1)
        let (c, _) = client([fake])
        XCTAssertEqual(try c.get("/DevMgmt/ProductStatusDyn.xml").text, status)
    }

    func testStaleBytesAreDrainedBeforeTheRequest() throws {
        let fake = FakeTransport(reply: Fixture.httpOK(status))
        fake.stale = [Fixture.httpOK(Fixture.consumablesTwoCartridges)]
        let (c, _) = client([fake])
        XCTAssertEqual(try c.get("/DevMgmt/ProductStatusDyn.xml").text, status)
        XCTAssertTrue(fake.stale.isEmpty)
    }

    func testLateReplyToEarlierRequestIsSkipped() throws {
        let both = Fixture.httpOK(Fixture.consumablesTwoCartridges) + Fixture.httpOK(status)
        let fake = FakeTransport(reply: both)
        let (c, _) = client([fake])
        XCTAssertEqual(try c.get("/DevMgmt/ProductStatusDyn.xml").text, status)
    }

    func testExplicitExpectRootOverridesDefault() throws {
        let fake = FakeTransport(reply: Fixture.httpOK(Fixture.calibrationState("CalibrationRequired")))
        let (c, _) = client([fake])
        let r = try c.get("/Calibration/State", expectRoot: "CalibrationState")
        XCTAssertEqual(r.status, 200)
    }

    func testHTTPErrorStatusIsReturnedNotThrown() throws {
        let fake = FakeTransport(reply: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8))
        let (c, _) = client([fake])
        let r = try c.get("/DevMgmt/ProductStatusDyn.xml")
        XCTAssertEqual(r.status, 404)
        XCTAssertEqual(r.reason, "Not Found")
    }

    // MARK: failure paths

    func testOpenFailureIsNotRetried() {
        var opens = 0
        let c = LEDMClient(serial: nil) { _, _ in opens += 1; throw LEDMError.deviceNotFound }
        XCTAssertThrowsError(try c.get("/DevMgmt/ProductStatusDyn.xml")) {
            guard case LEDMError.deviceNotFound = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(opens, 1)
        XCTAssertThrowsError(try c.withSession { _ in }) {
            guard case LEDMError.deviceNotFound = $0 else { return XCTFail("\($0)") }
        }
    }

    func testIOErrorOnReadIsNotRetried() {
        let fake = FakeTransport(replies: [.data(Data("HTTP/1.1 200 OK\r\nContent-Le".utf8)),
                                           .fail(LEDMError.io("device gone"))])
        let (c, opened) = client([fake])
        XCTAssertThrowsError(try c.get("/DevMgmt/ProductStatusDyn.xml")) {
            guard case LEDMError.io = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(opened(), 1)
    }

    func testIOErrorOnWriteIsNotRetried() {
        let fake = FakeTransport()
        fake.failWrite = LEDMError.io("pipe stalled")
        let (c, opened) = client([fake])
        XCTAssertThrowsError(try c.get("/DevMgmt/ProductStatusDyn.xml"))
        XCTAssertEqual(opened(), 1)
    }

    func testSilentPrinterTimesOutAfterOneRetryForGet() {
        let fake = FakeTransport()
        let (c, opened) = client([fake], timeout: 0.05)
        XCTAssertThrowsError(try c.get("/DevMgmt/ProductStatusDyn.xml")) {
            guard case LEDMError.timeout = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(opened(), 2)
    }

    func testWritesAreNotRetried() {
        let xml = Maintenance.jobXML("cleaningPage")
        let calls: [(LEDMClient) throws -> LEDMResponse] = [
            { try $0.put("/p", xml: xml) }, { try $0.post("/p", xml: xml) }, { try $0.postFooter("/p", xml: xml) },
        ]
        for call in calls {
            let (c, opened) = client([FakeTransport()], timeout: 0.05)
            XCTAssertThrowsError(try call(c))
            XCTAssertEqual(opened(), 1)
        }
    }

    func testRetrySucceedsAfterSilentFirstAttempt() throws {
        let silent = FakeTransport()
        let good = FakeTransport(reply: Fixture.httpOK(status))
        let (c, opened) = client([silent, good], timeout: 0.05)
        XCTAssertEqual(try c.get("/DevMgmt/ProductStatusDyn.xml").text, status)
        XCTAssertEqual(opened(), 2)
    }

    func testRetryRecoversFromBadReply() throws {
        let bad = FakeTransport(reply: Data(String(repeating: "x", count: LEDMReplyReader.maxBuffer + 1).utf8))
        let good = FakeTransport(reply: Fixture.httpOK(status))
        let (c, opened) = client([bad, good])
        XCTAssertEqual(try c.get("/DevMgmt/ProductStatusDyn.xml").text, status)
        XCTAssertEqual(opened(), 2)
    }

    func testDisconnectMidReply() {
        let raw = Fixture.httpOK(status)
        let fake = FakeTransport(replies: [.data(raw.prefix(raw.count / 2)), .fail(LEDMError.io("device removed (-536870160)"))])
        let (c, _) = client([fake])
        XCTAssertThrowsError(try c.get("/DevMgmt/ProductStatusDyn.xml")) {
            XCTAssertTrue("\($0.localizedDescription)".contains("USB transfer failed"))
        }
    }

    func testTruncatedReplyTimesOut() {
        let raw = Fixture.httpOK(status)
        let fake = FakeTransport(reply: raw.dropLast(5))
        let (c, _) = client([fake], timeout: 0.05)
        XCTAssertThrowsError(try c.get("/DevMgmt/ProductStatusDyn.xml")) {
            guard case LEDMError.timeout = $0 else { return XCTFail("\($0)") }
        }
    }

    func testNeverEndingChunkedBodyFailsInsteadOfGrowing() {
        let head = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        let fake = FakeTransport(reply: head)
        fake.endless = Data("1000\r\n".utf8) + Data(repeating: 0x41, count: 0x1000) + Data("\r\n".utf8)
        let (c, _) = client([fake], timeout: 5)
        let start = Date()
        XCTAssertThrowsError(try c.get("/DevMgmt/ProductStatusDyn.xml")) {
            guard case LEDMError.badReply = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testEndlessJunkWithoutHeaderEndFails() {
        let fake = FakeTransport()
        fake.endless = Data(repeating: 0x41, count: 16384)
        let (c, _) = client([fake], timeout: 5)
        XCTAssertThrowsError(try c.get("/DevMgmt/ProductStatusDyn.xml")) {
            guard case LEDMError.badReply = $0 else { return XCTFail("\($0)") }
        }
    }

    func testHugeContentLengthWaitingForBodyFails() {
        let head = Data("HTTP/1.1 200 OK\r\nContent-Length: 99999999999\r\n\r\n".utf8)
        let fake = FakeTransport(reply: head)
        fake.endless = Data(repeating: 0x41, count: 16384)
        let (c, _) = client([fake], timeout: 5)
        XCTAssertThrowsError(try c.get("/DevMgmt/ProductStatusDyn.xml")) {
            guard case LEDMError.badReply = $0 else { return XCTFail("\($0)") }
        }
    }

    func testMalformedStatusLinesAreSkippedAsJunk() throws {
        for junk in ["HTTP/1.1\r\n\r\n", "HTTP/1.1 abc OK\r\n\r\n", "SPAM 200 OK\r\n\r\n", "\r\n\r\n"] {
            let fake = FakeTransport(reply: Data(junk.utf8) + Fixture.httpOK(status))
            let (c, _) = client([fake])
            XCTAssertEqual(try c.get("/DevMgmt/ProductStatusDyn.xml").text, status, junk)
        }
    }

    func testMalformedHeaderLinesAreIgnored() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nno colon here\r\n: empty name\r\nContent-Length: \(status.utf8.count)\r\n\r\n\(status)".utf8)
        let (c, _) = client([FakeTransport(reply: raw)])
        let r = try c.get("/DevMgmt/ProductStatusDyn.xml")
        XCTAssertEqual(r.text, status)
        XCTAssertEqual(r.headers["content-length"], "\(status.utf8.count)")
    }

    func testBadContentLengthMeansEmptyBody() throws {
        let raw = Data("HTTP/1.1 500 Oops\r\nContent-Length: lots\r\n\r\n".utf8)
        let (c, _) = client([FakeTransport(reply: raw)])
        let r = try c.get("/DevMgmt/ProductStatusDyn.xml")
        XCTAssertEqual(r.status, 500)
        XCTAssertTrue(r.body.isEmpty)
    }

    func testBadChunkSizeEndsBodyAtWhatWasDecoded() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\nZZ\r\n".utf8)
        let (c, _) = client([FakeTransport(reply: raw)])
        let r = try c.get("/Other/Path", expectRoot: nil)
        XCTAssertEqual(r.text, "abc")
    }

    // MARK: reply reader limit

    func testReaderDropsBufferPastTheLimit() {
        var reader = LEDMReplyReader(expectRoot: nil)
        XCTAssertNil(reader.feed(Data(repeating: 0x41, count: LEDMReplyReader.maxBuffer)))
        XCTAssertFalse(reader.overflowed)
        XCTAssertNil(reader.feed(Data([0x41])))
        XCTAssertTrue(reader.overflowed)
        XCTAssertTrue(reader.buffer.isEmpty)
    }

    func testReaderAcceptsLargeCompleteReply() throws {
        let big = "<a>" + String(repeating: "x", count: LEDMReplyReader.maxBuffer + 10) + "</a>"
        var reader = LEDMReplyReader(expectRoot: nil)
        XCTAssertEqual(try XCTUnwrap(reader.feed(Fixture.httpOK(big))).body.count, big.utf8.count)
        XCTAssertFalse(reader.overflowed)
    }

    // MARK: session

    func testSessionSendsSeveralRequestsOnOneConnection() throws {
        let fake = FakeTransport()
        fake.onWrite = { req in
            let s = String(decoding: req, as: UTF8.self)
            return [.data(Fixture.httpOK(s.hasPrefix("GET /a") ? "<A/>" : "<B/>"))]
        }
        var opens = 0
        let c = LEDMClient(serial: nil, channel: .scan) { _, ch in
            opens += 1
            if case .scan = ch {} else { XCTFail("channel not passed through") }
            return fake
        }
        c.verbose = true
        var lines: [String] = []
        let out = try c.withSession { s -> [String] in
            s.log = { lines.append($0) }
            let a = try s.send(LEDMHTTP.getRequest("/a"), expectRoot: "A", timeout: 1)
            let b = try s.send(LEDMHTTP.getRequest("/b"), expectRoot: "B", timeout: 1)
            return [a.text, b.text]
        }
        XCTAssertEqual(out, ["<A/>", "<B/>"])
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(fake.written.count, 2)
        XCTAssertEqual(lines.first, ">> GET /a HTTP/1.1")
        XCTAssertTrue(lines.contains { $0.hasPrefix("<< 200 OK") })
    }

    func testSessionTimeoutAndOverflow() throws {
        let c1 = LEDMClient(serial: nil) { _, _ in FakeTransport() }
        XCTAssertThrowsError(try c1.withSession { try $0.send(LEDMHTTP.getRequest("/a"), expectRoot: nil, timeout: 0.05) }) {
            guard case LEDMError.timeout = $0 else { return XCTFail("\($0)") }
        }
        let fake = FakeTransport()
        fake.endless = Data(repeating: 0x41, count: 16384)
        let c2 = LEDMClient(serial: nil) { _, _ in fake }
        XCTAssertThrowsError(try c2.withSession { try $0.send(LEDMHTTP.getRequest("/a"), expectRoot: nil, timeout: 5) }) {
            guard case LEDMError.badReply = $0 else { return XCTFail("\($0)") }
        }
    }

    // MARK: async wrappers

    func testAsyncWrappers() async throws {
        let (c, _) = client([FakeTransport(reply: Fixture.httpOK(status))])
        let g = try await c.getAsync("/DevMgmt/ProductStatusDyn.xml")
        XCTAssertEqual(g.text, status)
        let ok = Fixture.httpOK("<a/>")
        let (c2, _) = client([FakeTransport(reply: ok)])
        let p = try await c2.postAsync("/p", xml: "<x/>")
        XCTAssertEqual(p.status, 200)
        let (c3, _) = client([FakeTransport(reply: ok)])
        let f = try await c3.postFooterAsync("/p", xml: "<x/>")
        XCTAssertEqual(f.status, 200)
        let (c4, _) = client([FakeTransport()], timeout: 0.05)
        do { _ = try await c4.getAsync("/DevMgmt/ProductStatusDyn.xml"); XCTFail("expected timeout") } catch {
            guard case LEDMError.timeout = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: clients registry

    func testClientsRegistry() {
        let reg = LEDMClients()
        let a = reg.client(for: "A"), a2 = reg.client(for: "A"), b = reg.client(for: nil)
        XCTAssertTrue(a === a2)
        XCTAssertFalse(a === b)
        XCTAssertEqual(reg.count, 2)
        reg.keepOnly("A")
        XCTAssertEqual(reg.count, 1)
        reg.drop("A")
        XCTAssertEqual(reg.count, 0)
        _ = reg.client(for: "C"); _ = reg.client(for: "D")
        reg.dropAll()
        XCTAssertEqual(reg.count, 0)
        XCTAssertNotNil(LEDMClients.shared)
    }

    func testErrorDescriptions() {
        let all: [LEDMError] = [.deviceNotFound, .open("x"), .io("x"), .timeout, .noLEDM, .badReply("x"), .http(500, "Err"), .canceled]
        for e in all { XCTAssertFalse((e.errorDescription ?? "").isEmpty) }
        XCTAssertEqual(LEDMError.http(500, "Err").errorDescription, "Printer returned HTTP 500 Err")
    }

    // MARK: download

    private func download(_ fake: FakeTransport, idle: TimeInterval = 0.1,
                          cancel: @escaping () -> Bool = { false },
                          progress: @escaping (Int) -> Void = { _ in }) throws -> (Int, Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        let c = LEDMClient(serial: nil, channel: .scan) { _, _ in fake }
        let n = try c.withSession {
            try $0.download(LEDMHTTP.scanGetRequest("/p"), to: fh, idleTimeout: idle, progress: progress, isCancelled: cancel)
        }
        return (n, try Data(contentsOf: url))
    }

    private let page = Data((0..<3000).map { UInt8($0 % 251) })

    func testDownloadContentLengthSplitEverywhere() throws {
        let head = Data("HTTP/1.1 200 OK\r\nContent-Length: \(page.count)\r\n\r\n".utf8)
        for chunk in [1, 7, 512, 100_000] {
            var seen: [Int] = []
            let (n, out) = try download(FakeTransport(reply: head + page, chunk: chunk), progress: { seen.append($0) })
            XCTAssertEqual(n, page.count)
            XCTAssertEqual(out, page)
            XCTAssertEqual(seen.last, page.count)
        }
    }

    func testDownloadChunked() throws {
        var wire = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        for start in stride(from: 0, to: page.count, by: 1000) {
            let part = page.subdata(in: start..<min(start + 1000, page.count))
            wire += Data("\(String(part.count, radix: 16))\r\n".utf8) + part + Data("\r\n".utf8)
        }
        wire += Data("0\r\n\r\n".utf8)
        let (n, out) = try download(FakeTransport(reply: wire, chunk: 333))
        XCTAssertEqual(n, page.count)
        XCTAssertEqual(out, page)
    }

    func testDownloadSkipsContinueJunkAndOne400() throws {
        let head = Data("HTTP/1.1 100 Continue\r\n\r\nnoise\r\n\r\nHTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nabcd".utf8)
        let (n, out) = try download(FakeTransport(reply: head))
        XCTAssertEqual(n, 4)
        XCTAssertEqual(out, Data("abcd".utf8))
    }

    func testDownloadSecond400Throws() {
        let wire = Data("HTTP/1.1 400 Bad\r\nContent-Length: 0\r\n\r\nHTTP/1.1 400 Bad\r\nContent-Length: 0\r\n\r\n".utf8)
        XCTAssertThrowsError(try download(FakeTransport(reply: wire))) {
            guard case LEDMError.http(400, _) = $0 else { return XCTFail("\($0)") }
        }
    }

    func testDownloadNon200Throws() {
        let wire = Data("HTTP/1.1 503 Busy\r\nContent-Length: 0\r\n\r\n".utf8)
        XCTAssertThrowsError(try download(FakeTransport(reply: wire))) {
            guard case LEDMError.http(503, "Busy") = $0 else { return XCTFail("\($0)") }
        }
    }

    func testDownloadWithoutLengthThrows() {
        let wire = Data("HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\n\r\nabc".utf8)
        XCTAssertThrowsError(try download(FakeTransport(reply: wire))) {
            guard case LEDMError.badReply = $0 else { return XCTFail("\($0)") }
        }
    }

    func testDownloadIdleTimeout() {
        let wire = Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nabc".utf8)
        XCTAssertThrowsError(try download(FakeTransport(reply: wire), idle: 0.05)) {
            guard case LEDMError.timeout = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try download(FakeTransport(), idle: 0.05)) {
            guard case LEDMError.timeout = $0 else { return XCTFail("\($0)") }
        }
    }

    func testDownloadCancel() {
        var polls = 0
        let wire = Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nabc".utf8)
        XCTAssertThrowsError(try download(FakeTransport(reply: wire), cancel: { polls += 1; return polls > 2 })) {
            guard case LEDMError.canceled = $0 else { return XCTFail("\($0)") }
        }
    }

    func testDownloadDisconnect() {
        let fake = FakeTransport(replies: [.data(Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nabc".utf8)),
                                           .fail(LEDMError.io("gone"))])
        XCTAssertThrowsError(try download(fake)) {
            guard case LEDMError.io = $0 else { return XCTFail("\($0)") }
        }
    }

    func testDownloadBadChunkSizeThrows() {
        let wire = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n".utf8)
        XCTAssertThrowsError(try download(FakeTransport(reply: wire)))
    }

    func testDownloadHeaderThatNeverEndsFails() {
        let fake = FakeTransport()
        fake.endless = Data(repeating: 0x41, count: 16384)
        XCTAssertThrowsError(try download(fake, idle: 5)) {
            guard case LEDMError.badReply = $0 else { return XCTFail("\($0)") }
        }
    }

    func testDownloadIgnoresBytesPastContentLength() throws {
        let wire = Data("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabcEXTRA".utf8)
        let (n, out) = try download(FakeTransport(reply: wire))
        XCTAssertEqual(n, 3)
        XCTAssertEqual(out, Data("abc".utf8))
    }

    func testParseHeadJunk() {
        let h = LEDMHTTP.parseHead(Data("junk\r\n\r\n".utf8))
        XCTAssertEqual(h?.status, -1)
        XCTAssertNil(LEDMHTTP.parseHead(Data("HTTP/1.1 200 OK\r\n".utf8)))
    }

    func testScanRequestsFrameBodies() {
        let xml = "<ScanSettings/>"
        let post = String(decoding: LEDMHTTP.scanPostRequest(xml: xml), as: UTF8.self)
        XCTAssertTrue(post.hasPrefix("POST /Scan/Jobs HTTP/1.1\r\n"))
        XCTAssertTrue(post.contains("Content-Length: \(xml.utf8.count + 7)\r\n"))
        XCTAssertTrue(post.hasSuffix("\(xml)\r\n0\r\n\r\n"))
        let get = String(decoding: LEDMHTTP.scanGetRequest("/Scan/Jobs/1"), as: UTF8.self)
        XCTAssertTrue(get.hasPrefix("GET /Scan/Jobs/1 HTTP/1.1\r\n"))
        let cancel = String(decoding: LEDMHTTP.scanCancelRequest("/Scan/Jobs/1", xml: xml), as: UTF8.self)
        XCTAssertTrue(cancel.hasPrefix("PUT /Scan/Jobs/1 HTTP/1.1\r\n"))
        XCTAssertTrue(cancel.contains("Content-Length: \(xml.utf8.count)\r\n"))
        XCTAssertTrue(cancel.hasSuffix(xml))
    }
}
