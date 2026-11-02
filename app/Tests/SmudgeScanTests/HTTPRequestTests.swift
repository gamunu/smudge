// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import XCTest
@testable import SmudgeScan

final class HTTPRequestParserTests: XCTestCase {
    private func parse(_ s: String) -> HTTPParseResult { HTTPRequestParser.parse(Data(s.utf8)) }

    private func request(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> (HTTPRequest, Int)? {
        guard case .request(let r, let n) = parse(s) else { XCTFail("not a request: \(parse(s))", file: file, line: line); return nil }
        return (r, n)
    }

    func testGetWithoutBody() throws {
        let wire = "GET /eSCL/ScannerStatus HTTP/1.1\r\nHost: localhost.:5000\r\n\r\n"
        let (r, n) = try XCTUnwrap(request(wire))
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/eSCL/ScannerStatus")
        XCTAssertEqual(r.headers["host"], "localhost.:5000")
        XCTAssertTrue(r.body.isEmpty)
        XCTAssertTrue(r.keepAlive)
        XCTAssertEqual(n, wire.utf8.count)
    }

    func testPostBodyAndPipelinedTail() throws {
        let wire = "POST /eSCL/ScanJobs HTTP/1.1\r\nContent-Length: 5\r\n\r\nhelloGET / HTTP/1.1\r\n"
        let (r, n) = try XCTUnwrap(request(wire))
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "hello")
        XCTAssertEqual(String(decoding: Data(wire.utf8).dropFirst(n), as: UTF8.self), "GET / HTTP/1.1\r\n")
    }

    func testEveryCutOfAValidRequestIsIncomplete() {
        let wire = Data("POST /eSCL/ScanJobs HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\nabcd".utf8)
        for cut in 0..<wire.count {
            XCTAssertEqual(HTTPRequestParser.parse(wire.prefix(cut)), .incomplete, "cut \(cut)")
        }
    }

    func testParsesFromASlicedBuffer() throws {
        let wire = Data("xxGET /a HTTP/1.1\r\n\r\n".utf8).dropFirst(2)
        guard case .request(let r, let n) = HTTPRequestParser.parse(wire) else { return XCTFail() }
        XCTAssertEqual(r.path, "/a")
        XCTAssertEqual(n, wire.count)
    }

    func testConnectionHeader() throws {
        XCTAssertFalse(try XCTUnwrap(request("GET / HTTP/1.1\r\nConnection: close\r\n\r\n")).0.keepAlive)
        XCTAssertFalse(try XCTUnwrap(request("GET / HTTP/1.0\r\n\r\n")).0.keepAlive)
        XCTAssertTrue(try XCTUnwrap(request("GET / HTTP/1.0\r\nConnection: Keep-Alive\r\n\r\n")).0.keepAlive)
    }

    func testMalformedRequestLines() {
        for line in ["GET /\r\n\r\n", "GET / HTTP/2\r\n\r\n", " / HTTP/1.1\r\n\r\n", "GET  / HTTP/1.1\r\n\r\n",
                     "GET http://evil/ HTTP/1.1\r\n\r\n", "GET / HTTP/1.1 x\r\n\r\n"] {
            XCTAssertEqual(parse(line), .invalid(status: 400), line)
        }
    }

    func testMalformedHeaders() {
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nno colon\r\n\r\n"), .invalid(status: 400))
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nBad Name: 1\r\n\r\n"), .invalid(status: 400))
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n"), .invalid(status: 400))
    }

    func testContentLengthMustBeDigits() {
        for v in ["-1", "+5", "1e3", "abc", "", " ", "٣"] {
            XCTAssertEqual(parse("POST / HTTP/1.1\r\nContent-Length: \(v)\r\n\r\n"), .invalid(status: 400), v)
        }
    }

    func testConflictingContentLengths() throws {
        XCTAssertEqual(parse("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab"), .invalid(status: 400))
        XCTAssertNotNil(request("POST / HTTP/1.1\r\nContent-Length: 2\r\ncontent-length: 2\r\n\r\nab"))
    }

    func testTransferEncodingRefused() {
        XCTAssertEqual(parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"), .invalid(status: 501))
    }

    func testSizeLimits() {
        let big = String(repeating: "a", count: 100)
        XCTAssertEqual(HTTPRequestParser.parse(Data("GET / HTTP/1.1\r\nX: \(big)".utf8), maxHeader: 64), .invalid(status: 431))
        XCTAssertEqual(HTTPRequestParser.parse(Data("GET / HTTP/1.1\r\nX: \(big)\r\n\r\n".utf8), maxHeader: 64), .invalid(status: 431))
        XCTAssertEqual(HTTPRequestParser.parse(Data("POST / HTTP/1.1\r\nContent-Length: 11\r\n\r\n".utf8), maxBody: 10),
                       .invalid(status: 413))
        XCTAssertEqual(parse("POST / HTTP/1.1\r\nContent-Length: 99999999999999999999\r\n\r\n"), .invalid(status: 400))
    }

    /// Random bytes and random cuts of real requests must never crash or read past the buffer.
    func testRandomInputNeverCrashes() {
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("GETPOST /eSCL:\r\n0123456789 Content-Length:Host".utf8) + [0, 0xff, 0x80]
        for _ in 0..<5_000 {
            let n = Int.random(in: 0..<200, using: &rng)
            let bytes = (0..<n).map { _ in alphabet.randomElement(using: &rng)! }
            if case .request(_, let used) = HTTPRequestParser.parse(Data(bytes)) {
                XCTAssertLessThanOrEqual(used, bytes.count)
            }
        }
    }
}

final class LoopbackPolicyTests: XCTestCase {
    private func req(host: String?, origin: String? = nil) -> HTTPRequest {
        var h: [String: String] = [:]
        h["host"] = host
        h["origin"] = origin
        return HTTPRequest(method: "GET", path: "/eSCL/ScannerStatus", headers: h, body: Data(), keepAlive: true)
    }

    func testImageCaptureHostPasses() {
        XCTAssertTrue(LoopbackPolicy.allows(req(host: "localhost.:5000"), port: 5000))
    }

    func testLoopbackNamesPass() {
        for h in ["localhost", "LOCALHOST:5000", "127.0.0.1:5000", "127.0.0.1", "[::1]:5000", "[::1]"] {
            XCTAssertTrue(LoopbackPolicy.allows(req(host: h), port: 5000), h)
        }
    }

    func testRebindingHostsFail() {
        for h in ["evil.example:5000", "evil.example", "localhost.evil.example:5000", "127.0.0.1.nip.io:5000",
                  "localhost:5001", "127.0.0.1:", "[::1]x", "[::1", "", "localhost:abc"] {
            XCTAssertFalse(LoopbackPolicy.allows(req(host: h), port: 5000), h)
        }
    }

    func testMissingHostFails() {
        XCTAssertFalse(LoopbackPolicy.allows(req(host: nil), port: 5000))
    }

    func testAnyOriginFails() {
        XCTAssertFalse(LoopbackPolicy.allows(req(host: "localhost:5000", origin: "http://localhost:5000"), port: 5000))
        XCTAssertFalse(LoopbackPolicy.allows(req(host: "localhost:5000", origin: "null"), port: 5000))
    }
}
