// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

/// One HTTP/1.1 request as the scanner agent reads it off the socket.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    /// Header names lowercased. A name sent twice keeps its last value.
    public var headers: [String: String]
    public var body: Data
    public var keepAlive: Bool
}

public enum HTTPParseResult: Equatable {
    /// Need more bytes.
    case incomplete
    /// A request and the number of buffer bytes it used.
    case request(HTTPRequest, consumed: Int)
    /// The bytes can never become a request we serve. Answer with this status and close.
    case invalid(status: Int)
}

/// Parses requests from the agent's receive buffer. Small on purpose: eSCL clients send
/// a request line, a few headers and at most an XML body with a Content-Length.
public enum HTTPRequestParser {
    public static let maxHeader = 64 * 1024
    public static let maxBody = 1024 * 1024

    public static func parse(_ buffer: Data, maxHeader: Int = maxHeader, maxBody: Int = maxBody) -> HTTPParseResult {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHeader ? .invalid(status: 431) : .incomplete
        }
        guard end.lowerBound - buffer.startIndex <= maxHeader else { return .invalid(status: 431) }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, !first[0].isEmpty, first[1].hasPrefix("/"),
              first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { return .invalid(status: 400) }

        var headers: [String: String] = [:]
        var length: Int?
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { return .invalid(status: 400) }
            let k = l[..<c].lowercased()
            let v = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty, !k.contains(" "), !k.contains("\t") else { return .invalid(status: 400) }
            if k == "content-length" {
                // Digits only, and every copy must agree, or a proxy and this server could
                // disagree on where the body ends.
                guard !v.isEmpty, v.allSatisfy(\.isASCII), v.allSatisfy(\.isNumber), let n = Int(v) else {
                    return .invalid(status: 400)
                }
                if let length, length != n { return .invalid(status: 400) }
                length = n
            }
            if k == "host", headers["host"] != nil { return .invalid(status: 400) }
            headers[k] = v
        }
        // No eSCL client sends a chunked request body.
        if headers["transfer-encoding"] != nil { return .invalid(status: 501) }
        let bodyLength = length ?? 0
        guard bodyLength <= maxBody else { return .invalid(status: 413) }

        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= bodyLength else { return .incomplete }
        var keepAlive = first[2] == "HTTP/1.1"
        if let c = headers["connection"]?.lowercased() {
            if c == "close" { keepAlive = false } else if c == "keep-alive" { keepAlive = true }
        }
        let req = HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers,
                              body: Data(buffer[bodyStart..<bodyStart + bodyLength]), keepAlive: keepAlive)
        return .request(req, consumed: bodyStart + bodyLength - buffer.startIndex)
    }
}

/// Decides whether a request on the loopback listener came from a local eSCL client.
///
/// The listener only accepts loopback peers, but a web page can still reach it: it can
/// rebind its own domain to 127.0.0.1, or post a form at it. Such requests carry the page's
/// domain in Host, or an Origin header. Image Capture sends `Host: localhost.:<port>` and no
/// Origin, so only loopback names pass.
public enum LoopbackPolicy {
    static let names: Set<String> = ["localhost", "localhost.", "127.0.0.1", "[::1]"]

    public static func allows(_ req: HTTPRequest, port: UInt16) -> Bool {
        if req.headers["origin"] != nil { return false }
        guard let host = req.headers["host"]?.lowercased() else { return false }
        let name: Substring
        let hostPort: Substring?
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return false }
            name = host[...close]
            let rest = host[host.index(after: close)...]
            if rest.isEmpty { hostPort = nil } else if rest.first == ":" { hostPort = rest.dropFirst() } else { return false }
        } else if let colon = host.lastIndex(of: ":") {
            name = host[..<colon]
            hostPort = host[host.index(after: colon)...]
        } else {
            name = host[...]
            hostPort = nil
        }
        guard names.contains(String(name)) else { return false }
        if let hostPort { return UInt16(hostPort) == port }
        return true
    }
}
