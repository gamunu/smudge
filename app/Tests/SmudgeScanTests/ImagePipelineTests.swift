// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import XCTest
import ImageIO
import CoreGraphics
@testable import SmudgeScan

func tmp(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("smudge-scan-tests")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(UUID().uuidString + "-" + name)
}

extension ScanPlan {
    static func test(output: ESCLFormat, layout: RawLayout, threshold: Int? = nil,
                     softwareBrightness: Int? = nil, sharpen: Int? = nil) -> ScanPlan {
        let req = LEDMScanRequest(resolution: 300, xStart: 0, yStart: 0, width: layout.width, height: layout.height,
                                  format: .raw, colorSpace: layout.channels == 3 ? "Color" : "Gray", brightness: 1000, contrast: 1000)
        return ScanPlan(request: req,
                        post: PostProcess(threshold: threshold, sharpen: sharpen, softwareBrightness: softwareBrightness, rawLayout: layout),
                        output: output)
    }
}

final class ToneAndPlanTests: XCTestCase {
    private func caps() throws -> LEDMScanCaps { try XCTUnwrap(LEDMScanCaps.parse(Data(ScanFixtures.scanCaps2336.utf8))) }

    func testPlannerBlackAndWhiteIsGrayRawWithThreshold() throws {
        let s = ESCLScanSettings(resolution: 300, x: 0, y: 0, width: 2550, height: 3300, colorMode: .blackAndWhite1, format: .pdf, threshold: 1000)
        let p = ScanPlanner.plan(s, caps: try caps(), tone: .deskJet2300)
        XCTAssertEqual(p.request.colorSpace, "Gray"); XCTAssertEqual(p.request.format, .raw); XCTAssertEqual(p.post.threshold, 1000)
        XCTAssertEqual(p.post.rawLayout, RawLayout(width: 2550, height: 3300, channels: 1, rowBytes: 2550))
    }

    func testPlannerJpegColorAndGrayStreamAsRawTIFF() throws {
        let c = ScanPlanner.plan(ESCLScanSettings(resolution: 300, x: 0, y: 0, width: 2480, height: 3508, colorMode: .rgb24, format: .jpeg),
                                 caps: try caps(), tone: .deskJet2300)
        XCTAssertTrue(c.streamsTIFF)
        XCTAssertEqual(c.request.format, .raw); XCTAssertEqual(c.request.colorSpace, "Color")
        XCTAssertEqual(c.post.rawLayout, RawLayout(width: 2480, height: 3508, channels: 3, rowBytes: 7440))
        let g = ScanPlanner.plan(ESCLScanSettings(resolution: 300, x: 0, y: 0, width: 2480, height: 3508, colorMode: .grayscale8, format: .jpeg,
                                                  brightness: 1500, contrast: 400),
                                 caps: try caps(), tone: .deskJet2300)
        XCTAssertTrue(g.streamsTIFF)
        XCTAssertEqual(g.request.format, .raw); XCTAssertEqual(g.request.colorSpace, "Gray")
        XCTAssertEqual(g.request.brightness, 1500); XCTAssertEqual(g.request.contrast, 400)   // tone stays on the device
    }

    func testPlannerJpegBlackAndWhiteStreamsWithThreshold() throws {
        let p = ScanPlanner.plan(ESCLScanSettings(resolution: 300, x: 0, y: 0, width: 2550, height: 3300, colorMode: .blackAndWhite1,
                                                  format: .jpeg, threshold: 700),
                                 caps: try caps(), tone: .deskJet2300)
        XCTAssertTrue(p.streamsTIFF)
        XCTAssertEqual(p.request.format, .raw); XCTAssertEqual(p.request.colorSpace, "Gray"); XCTAssertEqual(p.post.threshold, 700)
    }

    func testPlannerSharpenAndOtherFormatsKeepTheProcessedPath() throws {
        let sharp = ScanPlanner.plan(ESCLScanSettings(resolution: 300, x: 0, y: 0, width: 100, height: 100, colorMode: .rgb24, format: .jpeg,
                                                      sharpen: 1500),
                                     caps: try caps(), tone: .deskJet2300)
        XCTAssertFalse(sharp.streamsTIFF); XCTAssertEqual(sharp.request.format, .jpeg); XCTAssertEqual(sharp.post.sharpen, 1500)
        for f in [ESCLFormat.png, .tiff, .pdf] {
            let p = ScanPlanner.plan(ESCLScanSettings(resolution: 300, x: 0, y: 0, width: 100, height: 100, colorMode: .rgb24, format: f),
                                     caps: try caps(), tone: .deskJet2300)
            XCTAssertFalse(p.streamsTIFF, "\(f)")
        }
    }

    func testPlannerPngAsksForRawColorAndScalesLayoutByResolution() throws {
        let s = ESCLScanSettings(resolution: 75, x: 0, y: 0, width: 300, height: 600, colorMode: .rgb24, format: .png)
        let p = ScanPlanner.plan(s, caps: try caps(), tone: .deskJet2300)
        XCTAssertEqual(p.request.format, .raw); XCTAssertEqual(p.request.colorSpace, "Color")
        XCTAssertEqual(p.post.rawLayout, RawLayout(width: 75, height: 150, channels: 3, rowBytes: 225))
    }

    func testPlannerSoftwareToneWhenDeviceDoesNotApplyIt() throws {
        let t = ToneCalibration(neutral: 1000, min: 0, max: 2000, deviceApplies: false)
        let s = ESCLScanSettings(resolution: 300, x: 0, y: 0, width: 100, height: 100, colorMode: .rgb24, format: .jpeg, brightness: 1500, contrast: 1000, sharpen: 1400)
        let p = ScanPlanner.plan(s, caps: try caps(), tone: t)
        XCTAssertEqual(p.request.brightness, 1000)
        XCTAssertEqual(p.post.softwareBrightness, 1500); XCTAssertNil(p.post.softwareContrast); XCTAssertEqual(p.post.sharpen, 1400)
        XCTAssertEqual(p.request.format, .jpeg)       // an adjustment does not switch the device to Raw
        let d = ToneCalibration(neutral: 1000, min: 0, max: 2000, deviceApplies: true)
        let q = ScanPlanner.plan(s, caps: try caps(), tone: d)
        XCTAssertEqual(q.request.brightness, 1500); XCTAssertNil(q.post.softwareBrightness)
    }
}

final class ImagePipelineTests: XCTestCase {
    private func ramp() throws -> URL {
        let raw = Data((0..<2).flatMap { _ in (0..<16).map { UInt8($0 * 16) } })
        let page = tmp("page.raw"); try raw.write(to: page); return page
    }
    private func decode(_ url: URL) throws -> CGImage {
        try XCTUnwrap(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil))
    }
    private func pixels(_ img: CGImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: img.width * img.height)
        let ctx = CGContext(data: &out, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return out
    }

    func testRenderRawGrayToOneBitPNGAndPDF() throws {
        let page = try ramp()
        var plan = ScanPlan.test(output: .png, layout: RawLayout(width: 16, height: 2, channels: 1, rowBytes: 16), threshold: 1000)
        let png = tmp("out.png")
        try ImagePipeline.render(page: page, plan: plan, resolution: 300, to: png)
        let img = try decode(png)
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(png as CFURL, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyDepth] as? Int, 1)      // stored as 1 bit per pixel
        XCTAssertEqual(img.width, 16)
        // Left half is below the threshold (black), right half white.
        let px = pixels(img)
        XCTAssertEqual(Array(px[0..<8]), [UInt8](repeating: 0, count: 8)); XCTAssertEqual(Array(px[8..<16]), [UInt8](repeating: 255, count: 8))
        plan = ScanPlan.test(output: .pdf, layout: RawLayout(width: 16, height: 2, channels: 1, rowBytes: 16), threshold: 1000)
        let pdfURL = tmp("out.pdf")
        try ImagePipeline.render(page: page, plan: plan, resolution: 300, to: pdfURL)
        let pdf = try XCTUnwrap(CGPDFDocument(pdfURL as CFURL)); XCTAssertEqual(pdf.numberOfPages, 1)
        XCTAssertEqual(pdf.page(at: 1)!.getBoxRect(.mediaBox).width, 16.0 / 300 * 72, accuracy: 0.01)
    }

    func testThresholdMovesWithValue() throws {
        let page = try ramp()
        let layout = RawLayout(width: 16, height: 2, channels: 1, rowBytes: 16)
        func whiteCount(_ t: Int) throws -> Int {
            let out = tmp("t.png")
            try ImagePipeline.render(page: page, plan: ScanPlan.test(output: .png, layout: layout, threshold: t), resolution: 300, to: out)
            return pixels(try decode(out)).filter { $0 == 255 }.count
        }
        let low = try whiteCount(500), mid = try whiteCount(1000), high = try whiteCount(1500)
        XCTAssertGreaterThan(low, mid); XCTAssertGreaterThan(mid, high)
    }

    func testSoftwareBrightnessChangesPixelsAndCarriesDPI() throws {
        let page = try ramp()
        let layout = RawLayout(width: 16, height: 2, channels: 1, rowBytes: 16)
        let base = tmp("base.png"), bright = tmp("bright.png")
        try ImagePipeline.render(page: page, plan: ScanPlan.test(output: .png, layout: layout), resolution: 600, to: base)
        try ImagePipeline.render(page: page, plan: ScanPlan.test(output: .png, layout: layout, softwareBrightness: 2000), resolution: 600, to: bright)
        XCTAssertEqual(pixels(try decode(base)), (0..<2).flatMap { _ in (0..<16).map { UInt8($0 * 16) } })
        XCTAssertGreaterThan(pixels(try decode(bright)).reduce(0) { $0 + Int($1) }, pixels(try decode(base)).reduce(0) { $0 + Int($1) })
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(base as CFURL, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyDPIWidth] as? Double, 600)
    }

    func testRawRgbToTiff() throws {
        let raw = Data((0..<4).flatMap { _ in [UInt8(255), 0, 0] })     // 2x2 red
        let page = tmp("rgb.raw"); try raw.write(to: page)
        let out = tmp("rgb.tiff")
        try ImagePipeline.render(page: page, plan: ScanPlan.test(output: .tiff, layout: RawLayout(width: 2, height: 2, channels: 3, rowBytes: 6)), resolution: 300, to: out)
        let img = try decode(out)
        XCTAssertEqual([img.width, img.height], [2, 2])
    }
}
