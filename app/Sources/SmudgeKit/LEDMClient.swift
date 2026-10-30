// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

/// Talks HTTP to the printer's embedded web server over the LEDM USB
/// interface, the same way HPLIP's EWS_LEDM channel does. One request at a
/// time; each request drains stale bytes first and reads until a full reply
/// whose root element matches the resource arrives.
public final class LEDMClient: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ledm.usb", qos: .utility)
    /// USB serial of the printer this client talks to. nil means the only attached HP device.
    public let serial: String?
    public let channel: LEDMChannel

    public init(serial: String?, channel: LEDMChannel = .management) {
        self.serial = serial
        self.channel = channel
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
        let conn = try LEDMUSBConnection(serial: serial, channel: channel)
        conn.drain(quiet: 1.0)
        try conn.write(request)
        let deadline = Date().addingTimeInterval(overallTimeout)
        var reader = LEDMReplyReader(expectRoot: expectRoot) { [self] in log($0) }
        while Date() < deadline {
            if let resp = reader.feed(try conn.read(timeout: 1.0)) { return resp }
        }
        throw LEDMError.timeout
    }
}

/// One client per printer serial. Requests to one printer are serialized by its client;
/// different printers do not wait for each other.
public final class LEDMClients: @unchecked Sendable {
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
