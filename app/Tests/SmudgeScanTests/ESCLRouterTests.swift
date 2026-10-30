// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import XCTest
import CoreGraphics
import ImageIO
@testable import SmudgeScan

/// A scanner that blocks inside `scan` until released, writes a small JPEG and records cancels.
final class FakeScanDevice: ScanDevice, @unchecked Sendable {
    let caps: LEDMScanCaps
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private(set) var cancels = 0
    private(set) var stateCalls = 0
    private(set) var scans = 0
    var state = "Idle"
    var failure: Error?
    var outcome: ScanOutcome?
    var autoRelease = false

    init(caps: LEDMScanCaps) { self.caps = caps }

    func release() { gate.signal() }

    func scannerState() throws -> String {
        lock.lock(); defer { lock.unlock() }
        stateCalls += 1
        return state
    }

    func scan(_ request: LEDMScanRequest, to file: URL, isCancelled: @escaping @Sendable () -> Bool) throws -> ScanOutcome {
        lock.lock(); scans += 1; lock.unlock()
        while !autoRelease, gate.wait(timeout: .now() + 0.01) == .timedOut {
            if isCancelled() {
                lock.lock(); cancels += 1; lock.unlock()
                return .canceledByClient
            }
        }
        if let failure { throw failure }
        if let outcome { return outcome }
        try FakeScanDevice.jpeg().write(to: file)
        return .page(bytes: 1)
    }

    static func jpeg() -> Data {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}

final class ESCLRouterTests: XCTestCase {
    private func makeRouter(blocked: @escaping @Sendable () -> Bool = { false }) throws -> (ESCLRouter, FakeScanDevice) {
        let caps = try XCTUnwrap(LEDMScanCaps.parse(Data(ScanFixtures.scanCaps2336.utf8)))
        let dev = FakeScanDevice(caps: caps)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("router-" + UUID().uuidString)
        let r = ESCLRouter(device: dev, name: "DeskJet 2300", uuid: UUID(), serial: "CN171232SB", tone: .deskJet2300,
                           workDir: dir, onActivity: { _ in }, blocked: blocked)
        return (r, dev)
    }

    private func text(_ r: RouterResponse) -> String {
        if case .data(let d) = r.body { return String(decoding: d, as: UTF8.self) }
        return ""
    }

    private func get(_ r: ESCLRouter, _ path: String) -> RouterResponse { r.handle(method: "GET", path: path, body: Data()) }
    private func post(_ r: ESCLRouter, _ body: Data = ScanFixtures.imageCaptureSettings) -> RouterResponse {
        r.handle(method: "POST", path: "/eSCL/ScanJobs", body: body)
    }

    func testHappyPathMatchesSpikeSequence() throws {
        let (r, dev) = try makeRouter()
        XCTAssertEqual(get(r, "/eSCL/ScannerCapabilities").status, 200)
        let p = post(r)
        XCTAssertEqual(p.status, 201); XCTAssertEqual(p.headers["Location"], "/eSCL/ScanJobs/1")
        XCTAssertTrue(text(get(r, "/eSCL/ScannerStatus")).contains("<pwg:JobUri>/eSCL/ScanJobs/1</pwg:JobUri>"))
        guard case .pending(let w) = get(r, "/eSCL/ScanJobs/1/NextDocument").body else { return XCTFail() }
        dev.release()
        guard case .file(_, let type) = w.wait() else { return XCTFail() }
        XCTAssertEqual(type, "image/jpeg")
        XCTAssertEqual(get(r, "/eSCL/ScanJobs/1/NextDocument").status, 404)
        XCTAssertEqual(r.handle(method: "DELETE", path: "/eSCL/ScanJobs/1", body: Data()).status, 200)
        XCTAssertTrue(text(get(r, "/eSCL/ScannerStatus")).contains("<pwg:JobState>Completed</pwg:JobState>"))
    }

    func testSecondJobWhileFirstRunsIs503ThenWorks() throws {
        let (r, dev) = try makeRouter()
        XCTAssertEqual(post(r).status, 201)
        XCTAssertEqual(post(r).status, 503)
        dev.release(); r.waitUntilIdle()
        XCTAssertEqual(post(r).status, 201)
        dev.release(); r.waitUntilIdle()
    }

    func testDeleteMidScanCancelsDevice() throws {
        let (r, dev) = try makeRouter()
        _ = post(r)
        XCTAssertEqual(r.handle(method: "DELETE", path: "/eSCL/ScanJobs/1", body: Data()).status, 200)
        r.waitUntilIdle()
        XCTAssertEqual(dev.cancels, 1)
        XCTAssertTrue(text(get(r, "/eSCL/ScannerStatus")).contains("<pwg:JobState>Canceled</pwg:JobState>"))
        XCTAssertEqual(post(r).status, 201)
        dev.release(); r.waitUntilIdle()
    }

    func testBadSettingsAre400AndStatusDoesNotHammerDevice() throws {
        let (r, dev) = try makeRouter()
        XCTAssertEqual(post(r, Data("<junk/>".utf8)).status, 400)
        for _ in 0..<20 { _ = get(r, "/eSCL/ScannerStatus") }
        XCTAssertLessThanOrEqual(dev.stateCalls, 1)
    }

    func testSettingsOutsideCapsAre400() throws {
        let (r, dev) = try makeRouter()
        let bad = String(decoding: ScanFixtures.imageCaptureSettings, as: UTF8.self)
            .replacingOccurrences(of: "<scan:XResolution>300", with: "<scan:XResolution>250")
        XCTAssertEqual(post(r, Data(bad.utf8)).status, 400)
        XCTAssertEqual(dev.scans, 0)
    }

    func testNotIdleDeviceIs503() throws {
        let (r, dev) = try makeRouter()
        dev.state = "BusyWithScanJob"
        XCTAssertEqual(post(r).status, 503)
        XCTAssertEqual(dev.scans, 0)
    }

    func testBlockedByMaintenanceIs503() throws {
        let (r, dev) = try makeRouter(blocked: { true })
        XCTAssertEqual(post(r).status, 503)
        XCTAssertEqual(dev.scans, 0)
    }

    func testDeviceFailureAbortsJobAndFreesScanner() throws {
        let (r, dev) = try makeRouter()
        dev.failure = NSError(domain: "usb", code: 1); dev.autoRelease = true
        XCTAssertEqual(post(r).status, 201)
        r.waitUntilIdle()
        XCTAssertTrue(text(get(r, "/eSCL/ScannerStatus")).contains("<pwg:JobState>Aborted</pwg:JobState>"))
        guard case .pending(let w) = get(r, "/eSCL/ScanJobs/1/NextDocument").body else { return XCTFail() }
        XCTAssertEqual(w.wait(), .failed)
        dev.failure = nil
        XCTAssertEqual(post(r).status, 201)
        r.waitUntilIdle()
    }

    func testNoDocumentEndsWithNoMorePages() throws {
        let (r, dev) = try makeRouter()
        dev.outcome = .noDocument; dev.autoRelease = true
        _ = post(r); r.waitUntilIdle()
        guard case .pending(let w) = get(r, "/eSCL/ScanJobs/1/NextDocument").body else { return XCTFail() }
        XCTAssertEqual(w.wait(), .noMorePages)
    }

    func testUnknownPathsAndJobsAre404() throws {
        let (r, _) = try makeRouter()
        XCTAssertEqual(get(r, "/eSCL/ScanJobs/9/NextDocument").status, 404)
        XCTAssertEqual(r.handle(method: "DELETE", path: "/eSCL/ScanJobs/9", body: Data()).status, 404)
        XCTAssertEqual(get(r, "/nope").status, 404)
        XCTAssertEqual(r.handle(method: "POST", path: "/eSCL/ScannerStatus", body: Data()).status, 404)
    }

    func testFinishedJobsAreForgottenAfterTheirLifetime() throws {
        let (r, dev) = try makeRouter()
        dev.autoRelease = true
        _ = post(r); r.waitUntilIdle()
        XCTAssertTrue(text(get(r, "/eSCL/ScannerStatus")).contains("/eSCL/ScanJobs/1"))
        r.expireFinishedJobs(olderThan: 0)
        XCTAssertFalse(text(get(r, "/eSCL/ScannerStatus")).contains("/eSCL/ScanJobs/1"))
    }
}
