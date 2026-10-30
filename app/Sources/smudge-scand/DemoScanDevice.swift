// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import CoreGraphics
import ImageIO
import SmudgeScan

/// A scanner that needs no hardware: it waits a moment and returns a gradient. `--serve --demo`
/// uses it to check the HTTP, Bonjour and Image Capture side on a Mac with no printer attached.
final class DemoScanDevice: ScanDevice, @unchecked Sendable {
    /// Seconds a scan takes, so a slow scan can be tried against Image Capture.
    let delay: Double

    init(delay: Double = 1) { self.delay = delay }

    let caps = LEDMScanCaps(model: "Smudge Demo Scanner", minWidth: 8, minHeight: 8, maxWidth: 2550, maxHeight: 3508,
                            resolutions: [75, 100, 200, 300, 600, 1200], maxOptical: 1200,
                            formats: [.k1: [.raw], .gray8: [.raw, .jpeg], .color8: [.raw, .jpeg]], hasADF: false)

    func scannerState() throws -> String { "Idle" }

    func scan(_ request: LEDMScanRequest, to file: URL, isCancelled: @escaping @Sendable () -> Bool) throws -> ScanOutcome {
        let end = Date().addingTimeInterval(delay)
        while Date() < end {
            if isCancelled() { return .canceledByClient }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let w = request.width * request.resolution / 300, h = request.height * request.resolution / 300
        let channels = request.colorSpace == "Color" ? 3 : 1
        if request.format == .raw {
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let fh = try FileHandle(forWritingTo: file)
            defer { try? fh.close() }
            for y in 0..<h {
                var row = [UInt8](repeating: 0, count: w * channels)
                for x in 0..<w {
                    let v = UInt8((x * 255) / max(w - 1, 1))
                    for c in 0..<channels { row[x * channels + c] = c == 0 ? v : UInt8((y * 255) / max(h - 1, 1)) }
                }
                try fh.write(contentsOf: row)
            }
            return .page(bytes: w * h * channels)
        }
        let space = channels == 3 ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray()
        let info = channels == 3 ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.none.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info),
              let dest = CGImageDestinationCreateWithURL(file as CFURL, "public.jpeg" as CFString, 1, nil) else { return .noDocument }
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 0.1, alpha: 1)
        ctx.fill(CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { return .noDocument }
        return .page(bytes: (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0)
    }
}
