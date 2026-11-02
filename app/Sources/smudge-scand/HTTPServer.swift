// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import Network
import SmudgeScan

/// HTTP/1.1 on 127.0.0.1 for one scanner. Binds the loopback address only, drops any
/// connection whose peer is not loopback, and refuses requests that came from a web page
/// (see `LoopbackPolicy`).
final class HTTPServer: @unchecked Sendable {  // connections and port are guarded by lock
    /// Image Capture opens one or two connections per scanner. More than this is not a client we serve.
    static let maxConnections = 16
    private let router: ESCLRouter
    private let log: ((String) -> Void)?
    private let listener: NWListener
    private let queue = DispatchQueue(label: "scand.http")
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private let lock = NSLock()
    private(set) var port: UInt16 = 0

    /// First listener failure, set from the listener's queue and read by init.
    private final class FailureBox: @unchecked Sendable {  // guarded by lock
        private let lock = NSLock()
        private var error: NWError?
        var value: NWError? { lock.lock(); defer { lock.unlock() }; return error }
        func set(_ e: NWError) { lock.lock(); error = e; lock.unlock() }
    }

    init(router: ESCLRouter, log: ((String) -> Void)? = nil) throws {
        self.router = router
        self.log = log
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        let failed = FailureBox()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e): failed.set(e); ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, failed.value == nil, let p = listener.port?.rawValue else {
            listener.cancel()
            throw failed.value ?? NWError.posix(.ETIMEDOUT)
        }
        lock.lock(); port = p; lock.unlock()
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let all = Array(connections.values)
        connections = [:]
        lock.unlock()
        for c in all { c.close() }
    }

    private func accept(_ nw: NWConnection) {
        lock.lock()
        let full = connections.count >= Self.maxConnections
        let port = port
        lock.unlock()
        if full {
            log?("refused connection: \(Self.maxConnections) already open")
            nw.cancel()
            return
        }
        let c = HTTPConnection(nw, router: router, port: port, queue: queue, log: log) { [weak self] conn in
            guard let self else { return }
            lock.lock(); connections[ObjectIdentifier(conn)] = nil; lock.unlock()
        }
        lock.lock(); connections[ObjectIdentifier(c)] = c; lock.unlock()
        c.start()
    }
}

private final class HTTPConnection: @unchecked Sendable {  // all mutable state is touched on `queue` only
    private static let chunkSize = 1024 * 1024
    /// A connection that sends no complete request for this long is closed. Only armed while
    /// waiting for a request, so a long scan behind NextDocument is not cut off.
    static let idleTimeout: TimeInterval = 30

    private let nw: NWConnection
    private let router: ESCLRouter
    private let port: UInt16
    private let queue: DispatchQueue
    private var idleTimer: DispatchWorkItem?
    private let onClose: (HTTPConnection) -> Void
    private let log: ((String) -> Void)?
    private var buffer = Data()
    private var closed = false

    init(_ nw: NWConnection, router: ESCLRouter, port: UInt16, queue: DispatchQueue, log: ((String) -> Void)?,
         onClose: @escaping (HTTPConnection) -> Void) {
        self.nw = nw
        self.log = log
        self.router = router
        self.port = port
        self.queue = queue
        self.onClose = onClose
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if !isLoopback(nw.currentPath?.remoteEndpoint ?? nw.endpoint) { close(); return }
                readRequest()
            case .failed, .cancelled: close()
            default: break
            }
        }
        nw.start(queue: queue)
    }

    func close() {
        guard !closed else { return }
        closed = true
        idleTimer?.cancel()
        idleTimer = nil
        nw.cancel()
        onClose(self)
    }

    private func isLoopback(_ e: NWEndpoint?) -> Bool {
        guard case .hostPort(let host, _)? = e else { return false }
        switch host {
        case .ipv4(let a): return a == IPv4Address.loopback
        case .ipv6(let a): return a == IPv6Address.loopback
        default: return false
        }
    }

    // MARK: request

    private func readRequest() {
        switch HTTPRequestParser.parse(buffer) {
        case .request(let req, let used):
            disarmIdle()
            buffer.removeFirst(used)
            if LoopbackPolicy.allows(req, port: port) {
                respond(to: req)
            } else {
                log?("refused \(req.method) \(req.path): host \(req.headers["host"] ?? "none"), origin \(req.headers["origin"] ?? "none")")
                reject(403)
            }
        case .invalid(let status):
            disarmIdle()
            reject(status)
        case .incomplete:
            armIdle()
            nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty { buffer.append(data) }
                if error != nil || (isComplete && (data ?? Data()).isEmpty) { close(); return }
                readRequest()
            }
        }
    }

    private func armIdle() {
        guard idleTimer == nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.close() }
        idleTimer = item
        queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: item)
    }

    private func disarmIdle() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    /// Answers once and closes. The buffer may hold a half-read body, so the connection cannot be reused.
    private func reject(_ status: Int) {
        send(head(status, ["Content-Length": "0"], keepAlive: false)) { [weak self] in self?.close() }
    }

    // MARK: response

    private static let reasons = [200: "OK", 201: "Created", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                                  413: "Content Too Large", 431: "Request Header Fields Too Large",
                                  500: "Internal Server Error", 501: "Not Implemented", 503: "Service Unavailable"]

    private func head(_ status: Int, _ headers: [String: String], keepAlive: Bool) -> Data {
        var s = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        return Data(s.utf8)
    }

    private func respond(to req: HTTPRequest) {
        let res = router.handle(method: req.method, path: req.path, body: req.body)
        log?("\(req.method) \(req.path) -> \(res.status)")
        var headers = res.headers
        switch res.body {
        case .none:
            headers["Content-Length"] = "0"
            send(head(res.status, headers, keepAlive: req.keepAlive), then: finish(req.keepAlive))
        case .data(let d):
            headers["Content-Length"] = "\(d.count)"
            send(head(res.status, headers, keepAlive: req.keepAlive) + d, then: finish(req.keepAlive))
        case .file(let url, let type):
            sendFile(url, type: type, status: res.status, headers: headers, keepAlive: req.keepAlive)
        case .stream(let stream):
            headers["Content-Type"] = stream.contentType
            headers["Content-Length"] = "\(stream.totalLength)"
            send(head(res.status, headers, keepAlive: req.keepAlive)) { [weak self] in self?.pump(stream, keepAlive: req.keepAlive) }
        }
    }

    private func finish(_ keepAlive: Bool) -> @Sendable () -> Void {
        { [weak self] in
            guard let self else { return }
            if keepAlive { readRequest() } else { close() }
        }
    }

    private func send(_ data: Data, then next: @escaping @Sendable () -> Void) {
        guard !closed else { return }
        nw.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() } else { next() }
        })
    }

    /// Sends the stream's bytes as they appear. A stream that fails ends the connection short of the
    /// Content-Length, so the client sees an error instead of a truncated file.
    private func pump(_ stream: PageStream, keepAlive: Bool) {
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let step = stream.next(limit: Self.chunkSize)
            queue.async {
                switch step {
                case .data(let data):
                    self.send(data) { self.pump(stream, keepAlive: keepAlive) }
                case .end:
                    stream.close()
                    self.finish(keepAlive)()
                case .failed:
                    stream.close()
                    self.close()
                }
            }
        }
    }

    private func sendFile(_ url: URL, type: String, status: Int, headers: [String: String], keepAlive: Bool) {
        guard let fh = try? FileHandle(forReadingFrom: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else {
            send(head(404, ["Content-Length": "0"], keepAlive: keepAlive), then: finish(keepAlive)); return
        }
        var h = headers
        h["Content-Type"] = type
        h["Content-Length"] = "\(size)"
        @Sendable func step() {
            let data = (try? fh.read(upToCount: Self.chunkSize)) ?? Data()
            if data.isEmpty { try? fh.close(); finish(keepAlive)(); return }
            send(data) { step() }
        }
        send(head(status, h, keepAlive: keepAlive)) { step() }
    }
}
