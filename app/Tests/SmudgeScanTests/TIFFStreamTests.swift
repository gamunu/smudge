// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import XCTest
import CoreGraphics
import ImageIO
@testable import SmudgeScan

final class TIFFStreamTests: XCTestCase {
    private func decode(_ data: Data) throws -> (CGImage, [CFString: Any]) {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        return (img, props)
    }

    private func rgba(_ img: CGImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &out, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return out
    }

    func testRGBPageDecodesWithSizeAndDPI() throws {
        let rows = Data([10, 20, 30, 40, 50, 60, 70, 80, 90,
                         200, 210, 220, 230, 240, 250, 1, 2, 3])
        let layout = TIFFLayout(geometry: PageGeometry(width: 3, height: 2, bytesPerLine: 9), channels: 3, dpi: 150, threshold: nil)
        XCTAssertEqual(layout.totalLength, layout.header.count + 18)
        let (img, props) = try decode(layout.header + layout.convert(rows))
        XCTAssertEqual(img.width, 3); XCTAssertEqual(img.height, 2)
        XCTAssertEqual(props[kCGImagePropertyDPIWidth] as? Double, 150)
        XCTAssertEqual(props[kCGImagePropertyDPIHeight] as? Double, 150)
        XCTAssertEqual(props[kCGImagePropertyDepth] as? Int, 8)
        let px = rgba(img)
        XCTAssertEqual(Array(px[0..<4]), [10, 20, 30, 255])
        XCTAssertEqual(Array(px[8..<12]), [70, 80, 90, 255])
        XCTAssertEqual(Array(px[12..<16]), [200, 210, 220, 255])
        XCTAssertEqual(Array(px[20..<24]), [1, 2, 3, 255])
    }

    func testGrayPageDecodes() throws {
        let rows = Data([0, 128, 255, 255, 128, 0])
        let layout = TIFFLayout(geometry: PageGeometry(width: 3, height: 2, bytesPerLine: 3), channels: 1, dpi: 300, threshold: nil)
        let (img, props) = try decode(layout.header + layout.convert(rows))
        XCTAssertEqual(img.width, 3); XCTAssertEqual(img.height, 2); XCTAssertEqual(img.bitsPerPixel, 8)
        XCTAssertEqual(props[kCGImagePropertyDPIWidth] as? Double, 300)
        var out = [UInt8](repeating: 0, count: 6)
        let ctx = CGContext(data: &out, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 3,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 3, height: 2))
        XCTAssertEqual(out, [0, 128, 255, 255, 128, 0])
    }

    func testBlackAndWhiteIsOneBitWithWhitePaperWhite() throws {
        // 9 pixels wide so a row spills into a second byte. Row 0 is white, row 1 black.
        let rows = Data(repeating: 255, count: 9) + Data(repeating: 0, count: 9)
        let layout = TIFFLayout(geometry: PageGeometry(width: 9, height: 2, bytesPerLine: 9), channels: 1, dpi: 200, threshold: 1000)
        XCTAssertEqual(layout.totalLength, layout.header.count + 4)
        let (img, props) = try decode(layout.header + layout.convert(rows))
        XCTAssertEqual(img.width, 9); XCTAssertEqual(img.height, 2)
        // ImageIO expands 1-bit pages to 8 bits on decode, so the file's own field says what was sent.
        XCTAssertEqual(tiffValue(layout.header, tag: 258), 1)
        XCTAssertEqual(tiffValue(layout.header, tag: 279), 4)
        XCTAssertEqual(props[kCGImagePropertyDPIWidth] as? Double, 200)
        var out = [UInt8](repeating: 7, count: 18)
        let ctx = CGContext(data: &out, width: 9, height: 2, bitsPerComponent: 8, bytesPerRow: 9,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 9, height: 2))
        XCTAssertEqual(Array(out[0..<9]), [UInt8](repeating: 255, count: 9))
        XCTAssertEqual(Array(out[9..<18]), [UInt8](repeating: 0, count: 9))
    }

    func testThresholdCutsAtTheMiddleOfTheScale() {
        let g = PageGeometry(width: 8, height: 1, bytesPerLine: 8)
        let row = Data([0, 127, 128, 255, 100, 130, 0, 255])
        let mid = TIFFLayout(geometry: g, channels: 1, dpi: 75, threshold: 1000)
        XCTAssertEqual(mid.convert(row), Data([0b0011_0101]))
        // A higher threshold turns more pixels black.
        let high = TIFFLayout(geometry: g, channels: 1, dpi: 75, threshold: 2000)
        XCTAssertEqual(high.convert(row), Data([0b0001_0001]))
    }

    func testRowPaddingIsStripped() {
        let layout = TIFFLayout(geometry: PageGeometry(width: 2, height: 2, bytesPerLine: 4), channels: 1, dpi: 75, threshold: nil)
        XCTAssertEqual(layout.convert(Data([1, 2, 0, 0, 3, 4, 0, 0])), Data([1, 2, 3, 4]))
    }

    func testExpectedGeometryFollowsTheRawRule() {
        let r = LEDMScanRequest(resolution: 75, xStart: 0, yStart: 0, width: 2550, height: 3508, format: .raw,
                                colorSpace: "Color", brightness: 1000, contrast: 1000)
        XCTAssertEqual(PageGeometry.expected(for: r), PageGeometry(width: 637, height: 877, bytesPerLine: 1911))
    }
}

/// The inline value of a tag in the first IFD of a little-endian TIFF.
func tiffValue(_ d: Data, tag: Int) -> Int? {
    func u16(_ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
    let count = u16(8)
    for i in 0..<count where u16(10 + i * 12) == tag {
        let type = u16(12 + i * 12)
        return type == 3 ? u16(18 + i * 12) : u16(18 + i * 12) | u16(20 + i * 12) << 16
    }
    return nil
}
