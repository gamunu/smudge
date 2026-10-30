// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import Network
import SmudgeScan

/// HTTP/1.1 on 127.0.0.1 for one scanner. Binds the loopback address only, and drops any
/// connection whose peer is not loopback.
final class HTTPServer {
    private let router: ESCLRouter
    private let log: ((String) -> Void)?
    private let listener: NWListener
    private let queue = DispatchQueue(label: "scand.http")
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private let lock = NSLock()
    private(set) var port: UInt16 = 0

    init(router: ESCLRouter, log: ((String) -> Void)? = nil) throws {
        self.router = router
        self.log = log
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        var failure: NWError?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e): failure = e; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, failure == nil, let p = listener.port?.rawValue else {
            listener.cancel()
            throw failure ?? NWError.posix(.ETIMEDOUT)
        }
        port = p
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
        let c = HTTPConnection(nw, router: router, queue: queue, log: log) { [weak self] conn in
            guard let self else { return }
            lock.lock(); connections[ObjectIdentifier(conn)] = nil; lock.unlock()
        }
        lock.lock(); connections[ObjectIdentifier(c)] = c; lock.unlock()
        c.start()
    }
}

private final class HTTPConnection {
    private static let maxHeader = 64 * 1024
    private static let maxBody = 1024 * 1024
    private static let chunkSize = 1024 * 1024

    private let nw: NWConnection
    private let router: ESCLRouter
    private let queue: DispatchQueue
    private let onClose: (HTTPConnection) -> Void
    private let log: ((String) -> Void)?
    private var buffer = Data()
    private var closed = false

    init(_ nw: NWConnection, router: ESCLRouter, queue: DispatchQueue, log: ((String) -> Void)?,
         onClose: @escaping (HTTPConnection) -> Void) {
        self.nw = nw
        self.log = log
        self.router = router
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
        if let (req, used) = parse() {
            buffer.removeFirst(used)
            respond(to: req)
            return
        }
        if buffer.count > Self.maxHeader + Self.maxBody { close(); return }
        nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { buffer.append(data) }
            if error != nil || (isComplete && (data ?? Data()).isEmpty) { close(); return }
            readRequest()
        }
    }

    private struct Request { var method: String; var path: String; var body: Data; var keepAlive: Bool }

    private func parse() -> (Request, Int)? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maxHeader { close() }
            return nil
        }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { close(); return nil }
        var length = 0
        var keepAlive = !(first.count > 2 && first[2] == "HTTP/1.0")
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            let k = l[..<c].lowercased(), v = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
            if k == "content-length" { length = Int(v) ?? 0 }
            if k == "connection" { keepAlive = v.lowercased() != "close" }
        }
        guard length >= 0, length <= Self.maxBody else { close(); return nil }
        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else { return nil }
        let body = Data(buffer[bodyStart..<bodyStart + length])
        return (Request(method: String(first[0]), path: String(first[1]), body: body, keepAlive: keepAlive),
                bodyStart + length - buffer.startIndex)
    }

    // MARK: response

    private static let reasons = [200: "OK", 201: "Created", 400: "Bad Request", 404: "Not Found", 500: "Internal Server Error", 503: "Service Unavailable"]

    private func head(_ status: Int, _ headers: [String: String], keepAlive: Bool) -> Data {
        var s = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        return Data(s.utf8)
    }

    private func respond(to req: Request) {
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
            headers["Transfer-Encoding"] = "chunked"
            send(head(res.status, headers, keepAlive: req.keepAlive)) { [weak self] in self?.pump(stream, keepAlive: req.keepAlive) }
        }
    }

    private func finish(_ keepAlive: Bool) -> () -> Void {
        { [weak self] in
            guard let self else { return }
            if keepAlive { readRequest() } else { close() }
        }
    }

    private func send(_ data: Data, then next: @escaping () -> Void) {
        guard !closed else { return }
        nw.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() } else { next() }
        })
    }

    /// Sends the stream's bytes as they appear. A stream that fails ends the connection without the
    /// terminating chunk, so the client sees an error instead of a short file.
    private func pump(_ stream: PageStream, keepAlive: Bool) {
        DispatchQueue.global().async { [weak self] in
            let step = stream.next(limit: Self.chunkSize)
            self?.queue.async {
                guard let self else { return }
                switch step {
                case .data(let data):
                    var out = Data("\(String(data.count, radix: 16))\r\n".utf8)
                    out.append(data)
                    out.append(Data("\r\n".utf8))
                    self.send(out) { self.pump(stream, keepAlive: keepAlive) }
                case .end:
                    stream.close()
                    self.send(Data("0\r\n\r\n".utf8), then: self.finish(keepAlive))
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
        func step() {
            let data = (try? fh.read(upToCount: Self.chunkSize)) ?? Data()
            if data.isEmpty { try? fh.close(); finish(keepAlive)(); return }
            send(data) { step() }
        }
        send(head(status, h, keepAlive: keepAlive)) { step() }
    }
}
