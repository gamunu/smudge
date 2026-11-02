// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

/// Size of a Raw page, as the job document reports it once the page is ready to upload.
public struct PageGeometry: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// Bytes per row in the printer's data.
    public var bytesPerLine: Int

    public init(width: Int, height: Int, bytesPerLine: Int) {
        self.width = width
        self.height = height
        self.bytesPerLine = bytesPerLine
    }

    /// What a Raw scan of `request` measures on the printer: floor(size * dpi / 300) in each direction,
    /// rows without padding.
    public static func expected(for request: LEDMScanRequest) -> PageGeometry {
        let w = request.width * request.resolution / 300
        return PageGeometry(width: w, height: request.height * request.resolution / 300,
                            bytesPerLine: w * (request.colorSpace == "Color" ? 3 : 1))
    }
}

/// The TIFF around a Raw page that is still being scanned. The header and the size of the pixel data
/// are known from the geometry alone, so the total length is fixed before the first row arrives.
/// Baseline, little endian, one uncompressed strip: 8-bit RGB, 8-bit gray or, with a threshold, 1-bit.
public struct TIFFLayout: Equatable, Sendable {
    public let geometry: PageGeometry
    public let channels: Int
    public let threshold: Int?
    public let header: Data
    /// Bytes of one row in the file.
    public let rowBytes: Int

    /// `channels` is 3 for RGB or 1 for gray. A `threshold` (0...2000) makes the page 1-bit black and white.
    public init(geometry: PageGeometry, channels: Int, dpi: Int, threshold: Int?) {
        self.geometry = geometry
        self.channels = channels
        self.threshold = threshold
        rowBytes = threshold == nil ? geometry.width * channels : (geometry.width + 7) / 8
        header = Self.header(geometry, channels: channels, bits: threshold == nil ? 8 : 1, dpi: dpi, dataLength: rowBytes * geometry.height)
    }

    public var dataLength: Int { rowBytes * geometry.height }
    public var totalLength: Int { header.count + dataLength }

    /// Rows of the printer's data in, rows of the file out. Whole rows only.
    func convert(_ rows: Data) -> Data {
        let src = geometry.bytesPerLine
        let n = rows.count / src
        let packed = geometry.width * channels
        if threshold == nil {
            if src == packed { return rows }
            var out = Data(capacity: n * packed)
            for y in 0..<n { out.append(rows[rows.startIndex + y * src ..< rows.startIndex + y * src + packed]) }
            return out
        }
        let cut = ImagePipeline.thresholdCut(threshold ?? 1000)
        var out = Data(count: n * rowBytes)
        rows.withUnsafeBytes { (s: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
                for y in 0..<n {
                    for x in 0..<geometry.width where s[y * src + x] >= cut {
                        o[y * rowBytes + x / 8] |= UInt8(0x80 >> (x % 8))   // 1 is white
                    }
                }
            }
        }
        return out
    }

    private static func header(_ g: PageGeometry, channels: Int, bits: Int, dpi: Int, dataLength: Int) -> Data {
        enum T: UInt16 { case short = 3, long = 4, rational = 5 }
        let rgb = channels == 3
        let entries = 13
        let ifdEnd = 8 + 2 + entries * 12 + 4
        let bitsAt = ifdEnd
        let resAt = ifdEnd + (rgb ? 6 : 0)
        let dataAt = resAt + 16

        var d = Data()
        func u16(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]) }
        func u32(_ v: Int) { u16(v & 0xffff); u16((v >> 16) & 0xffff) }
        func entry(_ tag: Int, _ type: T, _ count: Int, _ value: Int) {
            u16(tag); u16(Int(type.rawValue)); u32(count)
            if type == .short, count == 1 { u16(value); u16(0) } else { u32(value) }
        }

        d.append(contentsOf: [0x49, 0x49, 42, 0])      // II, 42
        u32(8)                                          // first IFD
        u16(entries)
        entry(256, .long, 1, g.width)                   // ImageWidth
        entry(257, .long, 1, g.height)                  // ImageLength
        entry(258, .short, rgb ? 3 : 1, rgb ? bitsAt : bits)
        entry(259, .short, 1, 1)                        // Compression: none
        entry(262, .short, 1, rgb ? 2 : 1)              // RGB, or BlackIsZero
        entry(273, .long, 1, dataAt)                    // StripOffsets
        entry(277, .short, 1, channels)                 // SamplesPerPixel
        entry(278, .long, 1, g.height)                  // RowsPerStrip
        entry(279, .long, 1, dataLength)                // StripByteCounts
        entry(282, .rational, 1, resAt)                 // XResolution
        entry(283, .rational, 1, resAt + 8)             // YResolution
        entry(284, .short, 1, 1)                        // PlanarConfiguration: chunky
        entry(296, .short, 1, 2)                        // ResolutionUnit: inch
        u32(0)                                          // no next IFD
        if rgb { u16(8); u16(8); u16(8) }
        u32(dpi); u32(1)
        u32(dpi); u32(1)
        return d
    }
}
