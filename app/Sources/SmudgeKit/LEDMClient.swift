// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

/// Talks HTTP to the printer's embedded web server over the LEDM USB
/// interface, the same way HPLIP's EWS_LEDM channel does. One request at a
/// time; each request drains stale bytes first and reads until a full reply
/// whose root element matches the resource arrives.
public final class LEDMClient: @unchecked Sendable {  // requests are serialized by lock
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ledm.usb", qos: .utility)
    /// USB serial of the printer this client talks to. nil means the only attached HP device.
    public let serial: String?
    public let channel: LEDMChannel
    /// Opens the transport for one request. USB by default; tests inject an in-memory fake.
    private let open: (String?, LEDMChannel) throws -> LEDMTransport

    public init(serial: String?, channel: LEDMChannel = .management,
                open: @escaping (String?, LEDMChannel) throws -> LEDMTransport = { try LEDMUSBConnection(serial: $0, channel: $1) }) {
        self.serial = serial
        self.channel = channel
        self.open = open
    }
    public var overallTimeout: TimeInterval = 18
    public var verbose = false

    // MARK: blocking API (call off the main thread)

    public func get(_ path: String, expectRoot: String? = nil) throws -> LEDMResponse {
        try send(LEDMHTTP.getRequest(path), expectRoot: expectRoot ?? Self.defaultRoot(path))
    }

    /// PUT in the format HPLIP uses for calibration data (base/maint.py, AlignType16Manual).
    public func put(_ path: String, xml: String) throws -> LEDMResponse {
        try send(LEDMHTTP.putRequest(path, xml: xml), expectRoot: nil, retry: false)
    }

    /// POST in the format of HPLIP's Device.post (base/device.py), used for
    /// the InternalPrintDyn job request.
    public func post(_ path: String, xml: String) throws -> LEDMResponse {
        try send(LEDMHTTP.postRequest(path, xml: xml), expectRoot: nil, retry: false)
    }

    /// POST in the format of HPLIP's LocalOpenerEWS_LEDM.open_hp footer branch
    /// (base/device.py), used for /Calibration/Session.
    public func postFooter(_ path: String, xml: String) throws -> LEDMResponse {
        try send(LEDMHTTP.postFooterRequest(path, xml: xml), expectRoot: nil, retry: false)
    }

    /// Opens the interface once and keeps it for the whole closure, under the client's lock. Other
    /// requests on this client wait until the closure returns.
    public func withSession<T>(_ body: (LEDMSession) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let conn = try open(serial, channel)
        conn.drain(quiet: 1.0)
        let session = LEDMSession(conn: conn)
        if verbose { session.log = { [self] in log($0) } }
        return try body(session)
    }

    // MARK: async wrappers (run on the serial LEDM queue)

    public func getAsync(_ path: String, expectRoot: String? = nil) async throws -> LEDMResponse {
        try await onQueue { try self.get(path, expectRoot: expectRoot) }
    }
    public func postAsync(_ path: String, xml: String) async throws -> LEDMResponse {
        try await onQueue { try self.post(path, xml: xml) }
    }
    public func postFooterAsync(_ path: String, xml: String) async throws -> LEDMResponse {
        try await onQueue { try self.postFooter(path, xml: xml) }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try work()) } catch { cont.resume(throwing: error) }
            }
        }
    }

    // MARK: core

    public static func defaultRoot(_ path: String) -> String? {
        guard path.hasPrefix("/DevMgmt/"), path.hasSuffix(".xml") else { return nil }
        return String(path.dropLast(4).split(separator: "/").last ?? "")
    }

    private func log(_ s: String) {
        if verbose { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    }

    private func send(_ request: Data, expectRoot: String?, retry: Bool = true) throws -> LEDMResponse {
        lock.lock(); defer { lock.unlock() }
        var lastError: Error = LEDMError.timeout
        for attempt in 0..<(retry ? 2 : 1) {
            do {
                return try attemptOnce(request, expectRoot: expectRoot)
            } catch let e as LEDMError {
                lastError = e
                switch e {
                case .timeout, .badReply: log("ledm attempt \(attempt) failed: \(e)")
                default: throw e
                }
            }
        }
        throw lastError
    }

    private func attemptOnce(_ request: Data, expectRoot: String?) throws -> LEDMResponse {
        let conn = try open(serial, channel)
        conn.drain(quiet: 1.0)
        try conn.write(request)
        let deadline = Date().addingTimeInterval(overallTimeout)
        var reader = LEDMReplyReader(expectRoot: expectRoot) { [self] in log($0) }
        while Date() < deadline {
            if let resp = reader.feed(try conn.read(timeout: 1.0)) { return resp }
            if reader.overflowed { throw LEDMError.badReply("reply too large") }
        }
        throw LEDMError.timeout
    }
}

/// One client per printer serial. Requests to one printer are serialized by its client;
/// different printers do not wait for each other.
public final class LEDMClients: @unchecked Sendable {  // clients is guarded by lock
    public static let shared = LEDMClients()
    private let lock = NSLock()
    private var clients: [String: LEDMClient] = [:]

    private static func key(_ serial: String?) -> String { serial ?? "" }

    public func client(for serial: String?) -> LEDMClient {
        lock.lock(); defer { lock.unlock() }
        if let c = clients[Self.key(serial)] { return c }
        let c = LEDMClient(serial: serial)
        clients[Self.key(serial)] = c
        return c
    }

    /// Forgets the client for a printer that was unplugged.
    public func drop(_ serial: String?) {
        lock.lock(); defer { lock.unlock() }
        clients[Self.key(serial)] = nil
    }

    public func dropAll() {
        lock.lock(); defer { lock.unlock() }
        clients = [:]
    }

    /// Forgets every client except the one for the selected printer.
    public func keepOnly(_ serial: String?) {
        lock.lock(); defer { lock.unlock() }
        clients = clients.filter { $0.key == Self.key(serial) }
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return clients.count }
}

/// Several requests over one open interface. Created by LEDMClient.withSession.
public final class LEDMSession {
    private let conn: LEDMTransport
    /// Called with each request line and reply status.
    public var log: ((String) -> Void)?

    init(conn: LEDMTransport) { self.conn = conn }

    private func requestLine(_ request: Data) -> String {
        String(decoding: request.prefix(while: { $0 != 0x0d }), as: UTF8.self)
    }

    /// Sends a request and waits for the reply, dropping junk and replies to earlier requests.
    public func send(_ request: Data, expectRoot: String?, timeout: TimeInterval) throws -> LEDMResponse {
        log?(">> \(requestLine(request))")
        try conn.write(request)
        var reader = LEDMReplyReader(expectRoot: expectRoot, log: log)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let resp = reader.feed(try conn.read(timeout: 1.0)) {
                log?("<< \(resp.status) \(resp.reason) (\(resp.body.count) bytes)")
                return resp
            }
            if reader.overflowed { throw LEDMError.badReply("reply too large") }
        }
        throw LEDMError.timeout
    }

    /// Streams the body of a GET reply into a file and returns the byte count. The body is never held
    /// whole in memory. Throws `.timeout` when no data arrives for `idleTimeout` seconds and
    /// `.canceled` when `isCancelled` turns true.
    public func download(_ request: Data, to file: FileHandle, idleTimeout: TimeInterval,
                         progress: (Int) -> Void, isCancelled: () -> Bool) throws -> Int {
        log?(">> \(requestLine(request))")
        try conn.write(request)
        var head = Data()
        var headDone = false
        var skipped400 = false
        var chunked = false
        var decoder = ChunkedDecoder()
        var remaining: Int?
        var written = 0
        var finished = false
        var last = Date()
        while !finished {
            if isCancelled() { throw LEDMError.canceled }
            // Each read hands back autoreleased buffers. A page runs to hundreds of MB, so without a pool
            // per pass they pile up until the loop returns.
            try autoreleasepool {
                let got = try conn.read(timeout: 1.0)
                if got.isEmpty {
                    if Date().timeIntervalSince(last) > idleTimeout { throw LEDMError.timeout }
                    return
                }
                last = Date()
                var payload = got
                if !headDone {
                    head.append(got)
                    payload = Data()
                    while !headDone, let h = LEDMHTTP.parseHead(head) {
                        let rest = Data(head.dropFirst(h.bodyStart))
                        head = rest
                        if h.status < 0 || h.status == 100 { continue }
                        if h.status == 400, !skipped400 { skipped400 = true; continue }
                        guard h.status == 200 else { throw LEDMError.http(h.status, h.reason) }
                        log?("<< \(h.status) \(h.reason) \(h.headers["transfer-encoding"] ?? h.headers["content-length"] ?? "")")
                        headDone = true
                        chunked = (h.headers["transfer-encoding"] ?? "").lowercased().contains("chunked")
                        remaining = h.headers["content-length"].flatMap { Int($0) }
                        payload = rest
                        head = Data()
                    }
                    if !headDone {
                        if head.count > LEDMReplyReader.maxBuffer { throw LEDMError.badReply("reply header too large") }
                        return
                    }
                }
                let body: Data
                if chunked {
                    let r = try decoder.feed(payload)
                    body = r.body
                    finished = r.done
                } else if let rem = remaining {
                    body = payload.prefix(rem)
                    remaining = rem - body.count
                    finished = remaining == 0
                } else {
                    throw LEDMError.badReply("page reply has no length")
                }
                if !body.isEmpty {
                    try file.write(contentsOf: body)
                    written += body.count
                    progress(written)
                }
            }
        }
        log?("<< body \(written) bytes")
        return written
    }
}
