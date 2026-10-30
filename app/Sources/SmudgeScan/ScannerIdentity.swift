// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import CryptoKit

/// What Image Capture sees as the scanner's identity. Stable per USB serial, so it keeps its
/// per-scanner settings across reconnects.
public enum ScannerIdentity {
    /// A name-based (version 5, SHA-1) UUID over "smudge-scan:" and the serial.
    public static func uuid(serial: String) -> UUID {
        // The DNS namespace, 6ba7b810-9dad-11d1-80b4-00c04fd430c8.
        let ns: [UInt8] = [0x6b, 0xa7, 0xb8, 0x10, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8]
        var h = Insecure.SHA1()
        h.update(data: Data(ns))
        h.update(data: Data(("smudge-scan:" + serial).utf8))
        var b = Array(h.finalize().prefix(16))
        b[6] = (b[6] & 0x0f) | 0x50
        b[8] = (b[8] & 0x3f) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// The model name, with the serial added only when two of the same model are attached.
    public static func name(model: String, serial: String, sameModelCount: Int) -> String {
        sameModelCount > 1 ? "\(model) (\(serial))" : model
    }
}
