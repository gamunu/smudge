// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import XCTest
@testable import SmudgeKit

final class PrinterActivityTests: XCTestCase {
    private func store() -> ActivityStore {
        ActivityStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    func testActivityRoundTripAndDeadPid() throws {
        let s = store()
        s.set(.scanning, serial: "CN1", writer: .scand)
        XCTAssertEqual(s.current(serial: "CN1", from: .scand, pidAlive: { _ in true }), .scanning)
        XCTAssertNil(s.current(serial: "CN1", from: .scand, pidAlive: { _ in false }))
        XCTAssertNil(s.current(serial: "CN1", from: .app, pidAlive: { _ in true }))
        s.set(nil, serial: "CN1", writer: .scand)
        XCTAssertNil(s.current(serial: "CN1", from: .scand, pidAlive: { _ in true }))
    }

    func testWritersAndSerialsDoNotMix() throws {
        let s = store()
        s.set(.scanning, serial: "CN1", writer: .scand)
        s.set(.maintenance, serial: "CN1", writer: .app)
        s.set(.scanning, serial: "CN2", writer: .scand)
        XCTAssertEqual(s.current(serial: "CN1", from: .app, pidAlive: { _ in true }), .maintenance)
        XCTAssertEqual(s.current(serial: "CN1", from: .scand, pidAlive: { _ in true }), .scanning)
        s.set(nil, serial: "CN1", writer: .app)
        XCTAssertNil(s.current(serial: "CN1", from: .app, pidAlive: { _ in true }))
        XCTAssertEqual(s.current(serial: "CN2", from: .scand, pidAlive: { _ in true }), .scanning)
    }

    func testOwnPidIsAliveAndGarbageFileIsNil() throws {
        let s = store()
        s.set(.maintenance, serial: "A/B", writer: .app)          // a slash in a serial must not escape the directory
        XCTAssertEqual(s.current(serial: "A/B", from: .app), .maintenance)
        try Data("not json".utf8).write(to: s.directory.appendingPathComponent("X.app.json"))
        XCTAssertNil(s.current(serial: "X", from: .app))
    }
}
