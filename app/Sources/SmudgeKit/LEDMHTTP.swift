// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

public struct LEDMResponse {
    public var status: Int
    public var reason: String
    public var headers: [String: String]   // lower-cased names
    public var body: Data

    public init(status: Int, reason: String, headers: [String: String], body: Data) {
        self.status = status
        self.reason = reason
        self.headers = headers
        self.body = body
    }

    public var text: String { String(decoding: body, as: UTF8.self) }
}

/// Minimal HTTP/1.1 reply framing for the printer's LEDM channel.
public enum LEDMHTTP {
    /// Returns the parsed response and the number of bytes it used, or nil when
    /// the buffer does not yet hold a complete reply.
    public static func parse(_ input: Data) -> (LEDMResponse, Int)? {
        let buf = Data(input)   // zero-based indices
        let crlf = Data("\r\n".utf8)
        let crlf2 = Data("\r\n\r\n".utf8)
        guard let hdrEnd = buf.range(of: crlf2) else { return nil }
        let head = String(decoding: buf[0..<hdrEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let code = Int(parts[1]) else {
            // Not a status line: junk, skip past this header block.
            return (LEDMResponse(status: -1, reason: "junk", headers: [:], body: Data()), hdrEnd.upperBound)
        }
        var headers: [String: String] = [:]
        for l in lines {
            if let c = l.firstIndex(of: ":") {
                headers[l[..<c].lowercased().trimmingCharacters(in: .whitespaces)] =
                    l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
            }
        }
        var pos = hdrEnd.upperBound
        let reason = parts.count > 2 ? String(parts[2]) : ""
        func make(_ body: Data) -> LEDMResponse {
            LEDMResponse(status: code, reason: reason, headers: headers, body: body)
        }
        if (headers["transfer-encoding"] ?? "").lowercased().contains("chunked") {
            var body = Data()
            while true {
                guard let lineEnd = buf.range(of: crlf, in: pos..<buf.count) else { return nil }
                let sizeStr = String(decoding: buf[pos..<lineEnd.lowerBound], as: UTF8.self)
                    .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard let size = Int(sizeStr, radix: 16) else {
                    return (make(body), lineEnd.upperBound)
                }
                pos = lineEnd.upperBound
                if size == 0 {
                    // The last chunk is followed by optional trailers and an empty line.
                    guard let end = buf.range(of: crlf, in: pos..<buf.count) else { return nil }
                    if end.lowerBound == pos { return (make(body), end.upperBound) }
                    guard let fin = buf.range(of: crlf2, in: pos..<buf.count) else { return nil }
                    return (make(body), fin.upperBound)
                }
                guard buf.count - pos >= size + 2 else { return nil }
                body.append(buf[pos..<pos + size])
                pos += size + 2
            }
        }
        if let cl = headers["content-length"], let n = Int(cl) {
            guard buf.count - pos >= n else { return nil }
            return (make(buf[pos..<pos + n]), pos + n)
        }
        // No framing: treat as an empty body.
        return (make(Data()), pos)
    }

    // Request formats copied from HPLIP (base/device.py, base/maint.py).

    public static func getRequest(_ path: String) -> Data {
        Data("GET \(path) HTTP/1.1\r\nHost: localhost\r\nAccept: text/plain\r\nUser-Agent: hplip\r\n\r\n".utf8)
    }

    /// PUT in the format HPLIP uses for calibration data (base/maint.py, AlignType16Manual).
    public static func putRequest(_ path: String, xml: String) -> Data {
        let body = Data(xml.utf8)
        var req = Data("PUT \(path) HTTP/1.1\r\nHost: localhost\r\nUser-Agent: hp\r\nAccept: text/plain\r\nAccept-Language: en-us,en\r\nAccept-Charset:utf-8\r\nContent-Type: text/xml\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        req.append(body)
        return req
    }

    /// POST in the format of HPLIP's Device.post, used for the InternalPrintDyn job request.
    public static func postRequest(_ path: String, xml: String) -> Data {
        let body = Data(xml.utf8)
        var req = Data("POST \(path) HTTP/1.1\r\nConnection: Keep-alive\r\nUser-agent: hplip/2.0\r\nHost: localhost\r\nContent-type: text/xml\r\nContent-length: \(body.count)\r\n\r\n".utf8)
        req.append(body)
        return req
    }

    /// POST in the format of HPLIP's LocalOpenerEWS_LEDM.open_hp footer branch, used for /Calibration/Session.
    public static func postFooterRequest(_ path: String, xml: String) -> Data {
        let body = Data(xml.utf8)
        var req = Data("POST \(path) HTTP/1.1\r\nContent-Type:text/xml\r\nContent-Length:\(body.count)\r\nAccept-Encoding: UTF-8\r\nHost:localhost\r\nUser-Agent:hplip\r\n\r\n".utf8)
        req.append(body)
        return req
    }

    /// Local name of the first XML element, namespace prefix removed.
    public static func rootElement(_ body: Data) -> String? {
        let s = String(decoding: body.prefix(4096), as: UTF8.self)
        var i = s.startIndex
        while let lt = s[i...].firstIndex(of: "<") {
            let n = s.index(after: lt)
            guard n < s.endIndex else { return nil }
            if s[n] == "?" || s[n] == "!" { i = n; continue }
            var end = n
            while end < s.endIndex, !" \t\r\n/>".contains(s[end]) { end = s.index(after: end) }
            return String(s[n..<end]).split(separator: ":").last.map(String.init)
        }
        return nil
    }
}

/// Collects bytes from the USB channel and hands back the first complete reply
/// that answers the request. Junk, 100 Continue and late replies to earlier
/// requests (wrong XML root) are dropped.
public struct LEDMReplyReader {
    public var buffer = Data()
    public let expectRoot: String?
    public var log: ((String) -> Void)?

    public init(expectRoot: String?, log: ((String) -> Void)? = nil) {
        self.expectRoot = expectRoot
        self.log = log
    }

    public mutating func feed(_ bytes: Data) -> LEDMResponse? {
        buffer.append(bytes)
        while let (resp, used) = LEDMHTTP.parse(buffer) {
            buffer = Data(buffer.dropFirst(used))
            if resp.status < 0 || resp.status == 100 { continue }
            if let want = expectRoot, resp.status == 200 {
                let got = LEDMHTTP.rootElement(resp.body)
                if got != want {
                    log?("ledm: stale reply root \(got ?? "nil"), want \(want)")
                    continue   // late reply to an earlier request; keep reading
                }
            }
            return resp
        }
        return nil
    }
}

