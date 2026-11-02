// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import XCTest
import CoreGraphics
import ImageIO
@testable import SmudgeScan

/// A scanner that blocks inside `scan` until released, writes a small JPEG and records cancels.
/// With `pieces` set it instead creates the file at once and appends one piece per `step()`.
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
    var pieces: [Data]?
    private let stepGate = DispatchSemaphore(value: 0)

    init(caps: LEDMScanCaps) { self.caps = caps }

    func release() { gate.signal() }
    func step() { stepGate.signal() }

    func scannerState() throws -> String {
        lock.lock(); defer { lock.unlock() }
        stateCalls += 1
        return state
    }

    func scan(_ request: LEDMScanRequest, to file: URL, isCancelled: @escaping @Sendable () -> Bool) throws -> ScanOutcome {
        lock.lock(); scans += 1; lock.unlock()
        if let pieces {
            // Like the printer, the page file only appears once the first data is ready.
            var fh: FileHandle?
            defer { try? fh?.close() }
            for piece in pieces {
                while stepGate.wait(timeout: .now() + 0.01) == .timedOut {
                    if isCancelled() {
                        lock.lock(); cancels += 1; lock.unlock()
                        return .canceledByClient
                    }
                }
                if fh == nil {
                    FileManager.default.createFile(atPath: file.path, contents: nil)
                    fh = try FileHandle(forWritingTo: file)
                }
                try fh?.write(contentsOf: piece)
            }
            return .page(bytes: pieces.reduce(0) { $0 + $1.count })
        }
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
    private func makeRouter(blocked: @escaping @Sendable () -> Bool = { false }, pageWait: TimeInterval = 20,
                            dir: URL? = nil) throws -> (ESCLRouter, FakeScanDevice) {
        let caps = try XCTUnwrap(LEDMScanCaps.parse(Data(ScanFixtures.scanCaps2336.utf8)))
        let dev = FakeScanDevice(caps: caps)
        let dir = dir ?? FileManager.default.temporaryDirectory.appendingPathComponent("router-" + UUID().uuidString)
        let r = ESCLRouter(device: dev, name: "DeskJet 2300", uuid: UUID(), serial: "CN171232SB", tone: .deskJet2300,
                           workDir: dir, onActivity: { _ in }, blocked: blocked, pageWait: pageWait)
        return (r, dev)
    }

    private func text(_ r: RouterResponse) -> String {
        if case .data(let d) = r.body { return String(decoding: d, as: UTF8.self) }
        return ""
    }

    private func stream(_ r: RouterResponse) -> PageStream? {
        if case .stream(let s) = r.body { return s }
        return nil
    }

    /// Reads until the stream is over; returns the bytes and how it ended.
    private func drain(_ s: PageStream) -> (Data, PageStream.Step) {
        var all = Data()
        while true {
            switch s.next() {
            case .data(let d): all.append(d)
            case let end: return (all, end)
            }
        }
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
        let s = try XCTUnwrap(stream(get(r, "/eSCL/ScanJobs/1/NextDocument")))
        XCTAssertEqual(s.contentType, "image/jpeg")
        dev.release()
        let (bytes, end) = drain(s)
        XCTAssertEqual(end, .end)
        XCTAssertEqual(bytes, FakeScanDevice.jpeg())
        XCTAssertEqual(get(r, "/eSCL/ScanJobs/1/NextDocument").status, 404)
        XCTAssertEqual(r.handle(method: "DELETE", path: "/eSCL/ScanJobs/1", body: Data()).status, 200)
        XCTAssertTrue(text(get(r, "/eSCL/ScannerStatus")).contains("<pwg:JobState>Completed</pwg:JobState>"))
    }

    func testPassthroughStreamsPiecesInOrder() throws {
        let (r, dev) = try makeRouter()
        let pieces = (0..<4).map { Data(repeating: UInt8($0 + 1), count: 1000 * ($0 + 1)) }
        dev.pieces = pieces
        _ = post(r)
        let res = get(r, "/eSCL/ScanJobs/1/NextDocument")
        XCTAssertEqual(res.status, 200)
        let s = try XCTUnwrap(stream(res))
        var got = Data()
        for piece in pieces {
            dev.step()
            while got.count < (pieces.prefix(while: { $0 != piece }).reduce(0) { $0 + $1.count }) + piece.count {
                guard case .data(let d) = s.next() else { return XCTFail() }
                got.append(d)
            }
        }
        r.waitUntilIdle()
        XCTAssertEqual(s.next(), .end)
        XCTAssertEqual(got, pieces.reduce(Data(), +))
        XCTAssertEqual(get(r, "/eSCL/ScanJobs/1/NextDocument").status, 404)
    }

    func testStreamNeverReadsAPageLeftByAnEarlierRun() throws {
        // Job ids start at 1 in every agent run, and finished pages stay in the work folder.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("router-" + UUID().uuidString)
        let (old, oldDev) = try makeRouter(dir: dir)
        oldDev.pieces = [Data(repeating: 0xEE, count: 5000)]
        _ = post(old)
        let first = try XCTUnwrap(stream(get(old, "/eSCL/ScanJobs/1/NextDocument")))
        oldDev.step(); old.waitUntilIdle()
        while case .data = first.next() {}

        let (r, dev) = try makeRouter(dir: dir)
        let fresh = Data(repeating: 0x11, count: 300)
        dev.pieces = [fresh]
        _ = post(r)
        let s = try XCTUnwrap(stream(get(r, "/eSCL/ScanJobs/1/NextDocument")))
        // Start reading before the printer has sent anything, as Image Capture does.
        let got = Box()
        let done = expectation(description: "stream read")
        DispatchQueue.global().async {
            while case .data(let d) = s.next() { got.append(d) }
            done.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.3)
        dev.step(); r.waitUntilIdle()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(got.data, fresh)
    }

    func testSecondNextDocumentWhileStreamingIs503() throws {
        let (r, dev) = try makeRouter()
        dev.pieces = [Data(repeating: 1, count: 10)]
        _ = post(r)
        XCTAssertNotNil(stream(get(r, "/eSCL/ScanJobs/1/NextDocument")))
        let again = get(r, "/eSCL/ScanJobs/1/NextDocument")
        XCTAssertEqual(again.status, 503)
        XCTAssertEqual(again.headers["Retry-After"], "2")
        dev.step(); r.waitUntilIdle()
        XCTAssertEqual(get(r, "/eSCL/ScanJobs/1/NextDocument").status, 404)
    }

    func testCancelMidStreamEndsStreamAsFailed() throws {
        let (r, dev) = try makeRouter()
        dev.pieces = [Data(repeating: 1, count: 100), Data(repeating: 2, count: 100)]
        _ = post(r)
        let s = try XCTUnwrap(stream(get(r, "/eSCL/ScanJobs/1/NextDocument")))
        dev.step()
        XCTAssertEqual(s.next(), .data(Data(repeating: 1, count: 100)))
        XCTAssertEqual(r.handle(method: "DELETE", path: "/eSCL/ScanJobs/1", body: Data()).status, 200)
        XCTAssertEqual(s.next(), .failed)
    }

    func testProcessedJobNotReadyIs503ThenFileThen404() throws {
        let (r, dev) = try makeRouter(pageWait: 0.05)
        let sharpened = String(decoding: ScanFixtures.imageCaptureSettings, as: UTF8.self)
            .replacingOccurrences(of: "</scan:ScanSettings>", with: "<scan:Sharpen>1500</scan:Sharpen></scan:ScanSettings>")
        XCTAssertEqual(post(r, Data(sharpened.utf8)).status, 201)
        for _ in 0..<2 {
            let res = get(r, "/eSCL/ScanJobs/1/NextDocument")
            XCTAssertEqual(res.status, 503)
            XCTAssertEqual(res.headers["Retry-After"], "2")
        }
        XCTAssertTrue(text(get(r, "/eSCL/ScannerStatus")).contains("<pwg:JobState>Processing</pwg:JobState>"))
        dev.release(); r.waitUntilIdle()
        let ready = get(r, "/eSCL/ScanJobs/1/NextDocument")
        guard case .file(_, let type) = ready.body else { return XCTFail() }
        XCTAssertEqual(ready.status, 200)
        XCTAssertEqual(type, "image/jpeg")
        XCTAssertEqual(get(r, "/eSCL/ScanJobs/1/NextDocument").status, 404)
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
        XCTAssertEqual(get(r, "/eSCL/ScanJobs/1/NextDocument").status, 500)
        dev.failure = nil
        XCTAssertEqual(post(r).status, 201)
        r.waitUntilIdle()
    }

    func testNoDocumentEndsWithNoMorePages() throws {
        let (r, dev) = try makeRouter()
        dev.outcome = .noDocument; dev.autoRelease = true
        _ = post(r); r.waitUntilIdle()
        XCTAssertEqual(get(r, "/eSCL/ScanJobs/1/NextDocument").status, 404)
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

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var d = Data()
    var data: Data { lock.lock(); defer { lock.unlock() }; return d }
    func append(_ x: Data) { lock.lock(); d.append(x); lock.unlock() }
}
