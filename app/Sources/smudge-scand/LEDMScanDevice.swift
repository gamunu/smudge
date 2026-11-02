// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import SmudgeKit
import SmudgeScan

/// A scanner reached over the LEDM scan interface (255/0xcc/0).
final class LEDMScanDevice: ScanDevice, @unchecked Sendable {
    let serial: String
    let caps: LEDMScanCaps
    private let client: LEDMClient
    var log: (@Sendable (String) -> Void)?
    /// Longest wait for a page to be ready before the job is canceled.
    static let jobDeadline: TimeInterval = 15 * 60

    init(serial: String, caps: LEDMScanCaps) {
        self.serial = serial
        self.caps = caps
        self.client = LEDMClient(serial: serial, channel: .scan)
    }

    /// Reads /Scan/ScanCaps from the scan interface. An empty serial means the only attached HP device.
    static func fetchCaps(serial: String?) throws -> LEDMScanCaps {
        let client = LEDMClient(serial: serial, channel: .scan)
        let r = try client.withSession { s in
            try s.send(LEDMHTTP.scanGetRequest("/Scan/ScanCaps"), expectRoot: nil, timeout: 10)
        }
        guard r.status == 200 else { throw LEDMError.http(r.status, r.reason) }
        guard let caps = LEDMScanCaps.parse(r.body) else { throw LEDMError.badReply("ScanCaps") }
        return caps
    }

    func scannerState() throws -> String {
        try client.withSession { s in
            let r = try s.send(LEDMHTTP.scanGetRequest("/Scan/Status"), expectRoot: nil, timeout: 10)
            guard r.status == 200 else { throw LEDMError.http(r.status, r.reason) }
            return LEDMScanStatus.scannerState(r.body) ?? "Unknown"
        }
    }

    func scan(_ request: LEDMScanRequest, to file: URL, isCancelled: @escaping @Sendable () -> Bool,
              onPageReady: @escaping @Sendable (PageGeometry) -> Void) throws -> ScanOutcome {
        try client.withSession { s in
            let log = self.log
            s.log = log
            let started = Date()
            func lap(_ what: String) { log?(String(format: "[%6.1fs] %@", Date().timeIntervalSince(started), what)) }

            let st = try s.send(LEDMHTTP.scanGetRequest("/Scan/Status"), expectRoot: nil, timeout: 10)
            guard LEDMScanStatus.scannerState(st.body) == "Idle" else { throw LEDMError.http(503, "scanner busy") }

            let post = try s.send(LEDMHTTP.scanPostRequest(xml: request.xml), expectRoot: nil, timeout: 15)
            guard (200..<300).contains(post.status), let loc = post.headers["location"] else {
                throw LEDMError.http(post.status, post.reason)
            }
            let jobURL = URLComponents(string: loc)?.path ?? loc
            lap("job \(jobURL)")

            // Every way out except a finished job cancels it, or the printer keeps scanning on its own.
            var ended = false
            func cancel() {
                guard !ended else { return }
                ended = true
                _ = try? s.send(LEDMHTTP.scanCancelRequest(jobURL, xml: LEDMScanJob.cancelXML), expectRoot: nil, timeout: 10)
                lap("cancel sent")
            }
            defer { cancel() }

            var page = ""
            var geometry: PageGeometry?
            var lastDoc = ""
            poll: while true {
                if isCancelled() { cancel(); return .canceledByClient }
                if Date().timeIntervalSince(started) > Self.jobDeadline { cancel(); throw LEDMError.timeout }
                let r = try s.send(LEDMHTTP.scanGetRequest(jobURL), expectRoot: nil, timeout: 15)
                if r.status == 200, r.text != lastDoc { lastDoc = r.text; log?(r.text) }
                let snapshot = LEDMJobSnapshot.parse(r.body)
                switch LEDMJobStep.next(snapshot) {
                case .wait: Thread.sleep(forTimeInterval: 0.5)
                case .upload(let url): page = url; geometry = snapshot.geometry; break poll
                case .finished(let outcome): ended = true; return outcome
                }
            }
            lap("ReadyToUpload")

            // A job document without the size gets the size a Raw scan of this request measures.
            onPageReady(geometry ?? PageGeometry.expected(for: request))
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let fh = try FileHandle(forWritingTo: file)
            defer { try? fh.close() }
            do {
                let n = try s.download(LEDMHTTP.scanGetRequest(page), to: fh, idleTimeout: 120,
                                       progress: { _ in }, isCancelled: isCancelled)
                ended = true
                lap("downloaded \(n) bytes")
                return .page(bytes: n)
            } catch LEDMError.canceled {
                cancel()
                return .canceledByClient
            }
        }
    }
}
