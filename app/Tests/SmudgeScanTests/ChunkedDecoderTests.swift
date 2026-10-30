// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import XCTest
@testable import SmudgeKit

final class ChunkedDecoderTests: XCTestCase {
    func testChunkedDecoderAcrossEveryCut() throws {
        let wire = Data("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8)
        for cut in 1..<wire.count {
            var d = ChunkedDecoder(); var out = Data(); var done = false
            for part in [wire.prefix(cut), wire.dropFirst(cut)] { let r = try d.feed(Data(part)); out += r.body; done = r.done }
            XCTAssertEqual(String(decoding: out, as: UTF8.self), "hello world", "cut \(cut)"); XCTAssertTrue(done)
        }
    }

    func testByteAtATimeWithExtensionAndTrailer() throws {
        let wire = Data("3;ext=1\r\nabc\r\n0\r\nX-T: 1\r\n\r\n".utf8)
        var d = ChunkedDecoder(); var out = Data(); var done = false
        for b in wire { let r = try d.feed(Data([b])); out += r.body; done = r.done }
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "abc"); XCTAssertTrue(done)
    }

    func testBadSizeLineThrows() {
        var d = ChunkedDecoder()
        XCTAssertThrowsError(try d.feed(Data("zz\r\n".utf8)))
    }
}
