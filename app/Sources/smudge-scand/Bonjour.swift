// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import dnssd

/// A `_uscan._tcp` Bonjour record visible on this Mac only. It registers on the local-only
/// interface, so no other machine can see it.
final class BonjourAdvert {
    private var ref: DNSServiceRef?

    init(name: String, port: UInt16, txt: [(String, String)]) throws {
        var record = TXTRecordRef()
        var storage = [UInt8](repeating: 0, count: 1300)
        TXTRecordCreate(&record, UInt16(storage.count), &storage)
        defer { TXTRecordDeallocate(&record) }
        for (k, v) in txt {
            let bytes = Array(v.utf8)
            let err = bytes.withUnsafeBufferPointer { buf -> DNSServiceErrorType in
                var dummy: UInt8 = 0
                return withUnsafePointer(to: &dummy) { d in
                    TXTRecordSetValue(&record, k, UInt8(bytes.count), bytes.isEmpty ? UnsafeRawPointer(d) : UnsafeRawPointer(buf.baseAddress!))
                }
            }
            guard err == kDNSServiceErr_NoError else { throw BonjourError.txt(k, err) }
        }
        var r: DNSServiceRef?
        let err = DNSServiceRegister(&r, 0, kDNSServiceInterfaceIndexLocalOnly, name, "_uscan._tcp", nil, nil,
                                     port.bigEndian, TXTRecordGetLength(&record), TXTRecordGetBytesPtr(&record),
                                     nil, nil)
        guard err == kDNSServiceErr_NoError, let r else { throw BonjourError.register(err) }
        ref = r
        DNSServiceSetDispatchQueue(r, DispatchQueue(label: "bonjour.\(name)"))
    }

    func stop() {
        if let ref { DNSServiceRefDeallocate(ref) }
        ref = nil
    }

    deinit { stop() }
}

enum BonjourError: Error, CustomStringConvertible {
    case txt(String, Int32)
    case register(Int32)

    var description: String {
        switch self {
        case .txt(let k, let e): return "Bonjour TXT key \(k) failed (\(e))"
        case .register(let e): return "Bonjour registration failed (\(e))"
        }
    }
}

enum ScanTXT {
    /// TXT keys for an eSCL scanner, in the order Image Capture's AirScan expects.
    static func records(name: String, formats: [String], uuid: String) -> [(String, String)] {
        [("txtvers", "1"), ("vers", "2.63"), ("rs", "eSCL"), ("ty", name), ("pdl", formats.joined(separator: ",")),
         ("cs", "color,grayscale,binary"), ("is", "platen"), ("uuid", uuid), ("duplex", "F"),
         ("representation", ""), ("note", "")]
    }
}
