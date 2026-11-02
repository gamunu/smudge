// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import XCTest
import CoreGraphics
import ImageIO
@testable import SmudgeScan

/// A scanner that blocks inside `scan` until released, writes a small JPEG and records cancels.
/// With `pieces` set it instead creates the file on the first `step()` and appends one piece per `step()`.
/// It reports the page size when the scan starts, `geometry` or else what a Raw scan of the request measures.
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
    var geometry: PageGeometry?
    var reportsGeometry = true
    private let stepGate = DispatchSemaphore(value: 0)

    init(caps: LEDMScanCaps) { self.caps = caps }

    func release() { gate.signal() }
    func step() { stepGate.signal() }

    func scannerState() throws -> String {
        lock.lock(); defer { lock.unlock() }
        stateCalls += 1
        return state
    }

    func scan(_ request: LEDMScanRequest, to file: URL, isCancelled: @escaping @Sendable () -> Bool,
              onPageReady: @escaping @Sendable (PageGeometry) -> Void) throws -> ScanOutcome {
        lock.lock(); scans += 1; lock.unlock()
        if reportsGeometry { onPageReady(geometry ?? PageGeometry.expected(for: request)) }
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

    /// Settings for a small page: 8 x 8 pixels at 300 dpi unless `width` says otherwise.
    private func settings(color: String = "RGB24", format: String = "image/jpeg", width: Int = 8, extra: String = "") -> Data {
        let xml = String(decoding: ScanFixtures.imageCaptureSettings, as: UTF8.self)
            .replacingOccurrences(of: "<pwg:Width>2480", with: "<pwg:Width>\(width)")
            .replacingOccurrences(of: "<pwg:Height>3508", with: "<pwg:Height>8")
            .replacingOccurrences(of: "<scan:ColorMode>RGB24", with: "<scan:ColorMode>\(color)")
            .replacingOccurrences(of: "image/jpeg", with: format)
            .replacingOccurrences(of: "</scan:ScanSettings>", with: extra + "</scan:ScanSettings>")
        return Data(xml.utf8)
    }

    /// Bytes of a color page of `rows` rows, 8 pixels wide: every byte is the row number.
    private func colorRows(_ rows: Range<Int>) -> Data { Data(rows.flatMap { y in [UInt8](repeating: UInt8(y), count: 24) }) }

    /// Reads until `count` bytes have arrived.
    private func read(_ s: PageStream, _ count: Int) -> Data {
        var got = Data()
        while got.count < count {
            guard case .data(let d) = s.next() else { break }
            got.append(d)
        }
        return got
    }

    private func decode(_ data: Data) throws -> (CGImage, [CFString: Any]) {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return (try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil)),
                CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:])
    }

    func testStreamedColorJobHasItsLengthBeforeAnyPixelsThenStreamsRows() throws {
        let (r, dev) = try makeRouter()
        dev.pieces = (0..<4).map { colorRows(($0 * 2)..<($0 * 2 + 2)) }
        XCTAssertEqual(post(r, settings()).status, 201)
        XCTAssertTrue(text(get(r, "/eSCL/ScannerStatus")).contains("<pwg:JobUri>/eSCL/ScanJobs/1</pwg:JobUri>"))
        let res = get(r, "/eSCL/ScanJobs/1/NextDocument")
        XCTAssertEqual(res.status, 200)
        let s = try XCTUnwrap(stream(res))
        XCTAssertEqual(s.contentType, "image/jpeg")
        // 8 + 2 + 13 entries of 12 + 4 + 6 (bits) + 16 (resolution) = 192 bytes of header, then 8 x 8 x 3.
        XCTAssertEqual(s.totalLength, 192 + 8 * 8 * 3)
        guard case .data(let head) = s.next() else { return XCTFail() }
        XCTAssertEqual(head.count, 192)

        var got = head
        for i in 0..<4 {
            dev.step()
            let piece = read(s, 48)
            XCTAssertEqual(piece, colorRows((i * 2)..<(i * 2 + 2)))
            got.append(piece)
        }
        XCTAssertEqual(s.next(), .end)
        XCTAssertEqual(got.count, s.totalLength)
        let (img, props) = try decode(got)
        XCTAssertEqual(img.width, 8); XCTAssertEqual(img.height, 8)
        XCTAssertEqual(props[kCGImagePropertyDPIWidth] as? Double, 300)
        r.waitUntilIdle()
        XCTAssertEqual(get(r, "/eSCL/ScanJobs/1/NextDocument").status, 404)
        XCTAssertEqual(r.handle(method: "DELETE", path: "/eSCL/ScanJobs/1", body: Data()).status, 200)
        XCTAssertTrue(text(get(r, "/eSCL/ScannerStatus")).contains("<pwg:JobState>Completed</pwg:JobState>"))
    }

    func testStreamedJobAsksTheDeviceForRawColorOrGray() throws {
        let caps = try XCTUnwrap(LEDMScanCaps.parse(Data(ScanFixtures.scanCaps2336.utf8)))
        func plan(_ color: String) throws -> ScanPlan {
            let parsed = try XCTUnwrap(ESCLScanSettings.parse(settings(color: color)))
            return ScanPlanner.plan(try parsed.validated(against: caps), caps: caps, tone: .deskJet2300)
        }
        let c = try plan("RGB24"), g = try plan("Grayscale8")
        XCTAssertTrue(c.streamsTIFF); XCTAssertEqual(c.request.format, .raw); XCTAssertEqual(c.request.colorSpace, "Color")
        XCTAssertTrue(g.streamsTIFF); XCTAssertEqual(g.request.format, .raw); XCTAssertEqual(g.request.colorSpace, "Gray")
    }

    func testStreamedBlackAndWhiteIsOneBitWithWhiteStayingWhite() throws {
        let (r, dev) = try makeRouter()
        // 16 x 8: the top four rows are paper white, the bottom four black.
        let white = Data(repeating: 255, count: 16 * 4), black = Data(repeating: 0, count: 16 * 4)
        dev.pieces = [white, black]
        XCTAssertEqual(post(r, settings(color: "BlackAndWhite1", width: 16)).status, 201)
        let s = try XCTUnwrap(stream(get(r, "/eSCL/ScanJobs/1/NextDocument")))
        // No bits array for 1-bit pages: 170 + 16 bytes of header, then 2 bytes per row.
        XCTAssertEqual(s.totalLength, 186 + 2 * 8)
        dev.step(); dev.step()
        let got = read(s, s.totalLength)
        XCTAssertEqual(s.next(), .end)
        XCTAssertEqual(got.count, s.totalLength)
        let (img, props) = try decode(got)
        XCTAssertEqual(tiffValue(got, tag: 258), 1)   // 1 bit per sample in the file itself
        var out = [UInt8](repeating: 9, count: 16 * 8)
        let ctx = CGContext(data: &out, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 16,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 16, height: 8))
        XCTAssertEqual(Array(out[0..<64]), [UInt8](repeating: 255, count: 64))
        XCTAssertEqual(Array(out[64..<128]), [UInt8](repeating: 0, count: 64))
        r.waitUntilIdle()
    }

    func testRowPaddingFromThePrinterIsStrippedFromTheStream() throws {
        let (r, dev) = try makeRouter()
        dev.geometry = PageGeometry(width: 8, height: 8, bytesPerLine: 28)
        let padded = Data((0..<8).flatMap { y in [UInt8](repeating: UInt8(y), count: 24) + [UInt8](repeating: 0xEE, count: 4) })
        dev.pieces = [padded.prefix(100), padded.dropFirst(100)]
        _ = post(r, settings())
        let s = try XCTUnwrap(stream(get(r, "/eSCL/ScanJobs/1/NextDocument")))
        XCTAssertEqual(s.totalLength, 192 + 8 * 8 * 3)
        _ = s.next()
        dev.step(); dev.step()
        XCTAssertEqual(read(s, 8 * 8 * 3), colorRows(0..<8))
        XCTAssertEqual(s.next(), .end)
        r.waitUntilIdle()
    }

    func testStreamedJobWithoutPageSizeIs503() throws {
        let (r, dev) = try makeRouter(pageWait: 0.05)
        dev.reportsGeometry = false
        dev.pieces = [colorRows(0..<8)]
        _ = post(r, settings())
        let res = get(r, "/eSCL/ScanJobs/1/NextDocument")
        XCTAssertEqual(res.status, 503)
        XCTAssertEqual(res.headers["Retry-After"], "2")
        XCTAssertEqual(r.handle(method: "DELETE", path: "/eSCL/ScanJobs/1", body: Data()).status, 200)
        r.waitUntilIdle()
        // A 503 does not serve the job.
        XCTAssertNotEqual(get(r, "/eSCL/ScanJobs/1/NextDocument").status, 200)
    }

    func testStreamNeverReadsAPageLeftByAnEarlierRun() throws {
        // Job ids start at 1 in every agent run, and finished pages stay in the work folder.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("router-" + UUID().uuidString)
        let (old, oldDev) = try makeRouter(dir: dir)
        oldDev.pieces = [Data(repeating: 0xEE, count: 8 * 8 * 3)]
        _ = post(old, settings())
        let first = try XCTUnwrap(stream(get(old, "/eSCL/ScanJobs/1/NextDocument")))
        oldDev.step(); old.waitUntilIdle()
        while case .data = first.next() {}

        let (r, dev) = try makeRouter(dir: dir)
        let fresh = Data(repeating: 0x11, count: 8 * 8 * 3)
        dev.pieces = [fresh]
        _ = post(r, settings())
        let s = try XCTUnwrap(stream(get(r, "/eSCL/ScanJobs/1/NextDocument")))
        _ = s.next()
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
        dev.pieces = [colorRows(0..<8)]
        _ = post(r, settings())
        XCTAssertNotNil(stream(get(r, "/eSCL/ScanJobs/1/NextDocument")))
        let again = get(r, "/eSCL/ScanJobs/1/NextDocument")
        XCTAssertEqual(again.status, 503)
        XCTAssertEqual(again.headers["Retry-After"], "2")
        dev.step(); r.waitUntilIdle()
        XCTAssertEqual(get(r, "/eSCL/ScanJobs/1/NextDocument").status, 404)
    }

    func testCancelMidStreamEndsStreamAsFailed() throws {
        let (r, dev) = try makeRouter()
        dev.pieces = [colorRows(0..<4), colorRows(4..<8)]
        _ = post(r, settings())
        let s = try XCTUnwrap(stream(get(r, "/eSCL/ScanJobs/1/NextDocument")))
        guard case .data = s.next() else { return XCTFail() }
        dev.step()
        XCTAssertEqual(s.next(), .data(colorRows(0..<4)))
        XCTAssertEqual(r.handle(method: "DELETE", path: "/eSCL/ScanJobs/1", body: Data()).status, 200)
        XCTAssertEqual(s.next(), .failed)
        r.waitUntilIdle()
        XCTAssertTrue(text(get(r, "/eSCL/ScannerStatus")).contains("<pwg:JobState>Canceled</pwg:JobState>"))
    }

    func testShortPageEndsStreamAsFailed() throws {
        let (r, dev) = try makeRouter()
        dev.pieces = [colorRows(0..<4)]
        _ = post(r, settings())
        let s = try XCTUnwrap(stream(get(r, "/eSCL/ScanJobs/1/NextDocument")))
        _ = s.next()
        dev.step(); r.waitUntilIdle()
        // The printer delivered half the page and the job ended: the stream must not end cleanly.
        XCTAssertEqual(s.next(), .data(colorRows(0..<4)))
        XCTAssertEqual(s.next(), .failed)
    }

    func testPngJobIsProcessedNotStreamed() throws {
        let (r, dev) = try makeRouter(pageWait: 0.05)
        XCTAssertEqual(post(r, settings(format: "image/png")).status, 201)
        XCTAssertEqual(get(r, "/eSCL/ScanJobs/1/NextDocument").status, 503)
        XCTAssertEqual(r.handle(method: "DELETE", path: "/eSCL/ScanJobs/1", body: Data()).status, 200)
        r.waitUntilIdle()
        XCTAssertEqual(dev.cancels, 1)
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
        dev.failure = NSError(domain: "usb", code: 1); dev.autoRelease = true; dev.reportsGeometry = false
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
        dev.outcome = .noDocument; dev.autoRelease = true; dev.reportsGeometry = false
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
