// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import CoreGraphics
import CoreImage
import ImageIO

/// Layout of a Raw page from the scanner: rows of `rowBytes`, `channels` bytes per pixel, no header.
public struct RawLayout: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var channels: Int
    public var rowBytes: Int

    public init(width: Int, height: Int, channels: Int, rowBytes: Int) {
        self.width = width
        self.height = height
        self.channels = channels
        self.rowBytes = rowBytes
    }
}

/// Work the agent does on a page after the scanner delivers it.
public struct PostProcess: Equatable, Sendable {
    /// 0...2000, set for BlackAndWhite1.
    public var threshold: Int?
    public var sharpen: Int?
    public var softwareBrightness: Int?
    public var softwareContrast: Int?
    public var rawLayout: RawLayout?

    public init(threshold: Int? = nil, sharpen: Int? = nil, softwareBrightness: Int? = nil,
                softwareContrast: Int? = nil, rawLayout: RawLayout? = nil) {
        self.threshold = threshold
        self.sharpen = sharpen
        self.softwareBrightness = softwareBrightness
        self.softwareContrast = softwareContrast
        self.rawLayout = rawLayout
    }
}

public struct ScanPlan: Equatable, Sendable {
    public var request: LEDMScanRequest
    public var post: PostProcess
    public var output: ESCLFormat

    public init(request: LEDMScanRequest, post: PostProcess, output: ESCLFormat) {
        self.request = request
        self.post = post
        self.output = output
    }
}

public enum ScanPlanner {
    /// Turns validated eSCL settings into the LEDM job to run and the work to do on its page.
    public static func plan(_ s: ESCLScanSettings, caps: LEDMScanCaps, tone: ToneCalibration) -> ScanPlan {
        let color = s.colorMode == .rgb24
        let bw = s.colorMode == .blackAndWhite1
        let type: LEDMColorType = color ? .color8 : .gray8
        var format: LEDMFormat = (s.format == .png || s.format == .tiff || bw) ? .raw : .jpeg
        // A color type that cannot do Raw falls back to Jpeg.
        if format == .raw, !(caps.formats[type]?.contains(.raw) ?? false) { format = .jpeg }

        var post = PostProcess()
        if bw { post.threshold = s.threshold ?? 1000 }
        if let sh = s.sharpen, sh != 1000 { post.sharpen = sh }

        var brightness = tone.neutral, contrast = tone.neutral
        if tone.deviceApplies {
            brightness = tone.device(s.brightness)
            contrast = tone.device(s.contrast)
        } else {
            if let b = s.brightness, b != 1000 { post.softwareBrightness = b }
            if let c = s.contrast, c != 1000 { post.softwareContrast = c }
        }

        if format == .raw {
            let px = s.width * s.resolution / 300
            let ch = color ? 3 : 1
            post.rawLayout = RawLayout(width: px, height: s.height * s.resolution / 300, channels: ch, rowBytes: px * ch)
        }
        let req = LEDMScanRequest(resolution: s.resolution, xStart: s.x, yStart: s.y, width: s.width, height: s.height,
                                  format: format, colorSpace: color ? "Color" : "Gray", brightness: brightness, contrast: contrast)
        return ScanPlan(request: req, post: post, output: s.format)
    }
}

enum ImagePipelineError: Error { case unreadable, encode, empty }

/// A read-only mapping of a page file. A 1200 dpi color page is about 400 MB, so it is never copied.
private final class MappedFile {
    let base: UnsafeMutableRawPointer
    let size: Int

    init(url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw ImagePipelineError.unreadable }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { throw ImagePipelineError.empty }
        size = Int(st.st_size)
        guard let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else { throw ImagePipelineError.unreadable }
        base = p
    }

    deinit { munmap(base, size) }
}

public enum ImagePipeline {
    /// Reads the page the scanner delivered, applies the plan's post steps and writes the output file.
    public static func render(page: URL, plan: ScanPlan, resolution: Int, to output: URL) throws {
        let post = plan.post
        let isRaw = plan.request.format == .raw
        if !isRaw, plan.output == .jpeg, post == PostProcess() {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: page, to: output)
            return
        }

        var mapped: MappedFile?
        var image: CGImage
        if isRaw {
            guard let layout = post.rawLayout else { throw ImagePipelineError.unreadable }
            let m = try MappedFile(url: page)
            mapped = m
            image = try rawImage(m, layout)
        } else {
            guard let src = CGImageSourceCreateWithURL(page as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw ImagePipelineError.unreadable }
            image = img
        }

        if post.softwareBrightness != nil || post.softwareContrast != nil || post.sharpen != nil {
            image = try adjust(image, post: post, resolution: resolution)
            mapped = nil
        }
        if let t = post.threshold {
            image = try threshold(image, level: t, rawGray: image.bitsPerPixel == 8 ? mapped : nil, oneBit: plan.output != .jpeg)
        }
        _ = mapped
        try encode(image, as: plan.output, resolution: resolution, to: output)
    }

    // MARK: decode

    private static func rawImage(_ m: MappedFile, _ layout: RawLayout) throws -> CGImage {
        guard layout.rowBytes > 0, layout.channels == 1 || layout.channels == 3 else { throw ImagePipelineError.unreadable }
        let rows = m.size / layout.rowBytes
        guard rows > 0 else { throw ImagePipelineError.empty }
        let info = Unmanaged.passRetained(m).toOpaque()
        guard let provider = CGDataProvider(dataInfo: info, data: m.base, size: m.size,
                                            releaseData: { info, _, _ in Unmanaged<MappedFile>.fromOpaque(info!).release() })
        else { throw ImagePipelineError.unreadable }
        let space = layout.channels == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let img = CGImage(width: layout.rowBytes / layout.channels, height: rows, bitsPerComponent: 8,
                                bitsPerPixel: 8 * layout.channels, bytesPerRow: layout.rowBytes, space: space,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw ImagePipelineError.unreadable }
        return img
    }

    // MARK: adjust

    private static func adjust(_ image: CGImage, post: PostProcess, resolution: Int) throws -> CGImage {
        let gray = image.colorSpace?.model == .monochrome
        var ci = CIImage(cgImage: image)
        let extent = ci.extent

        if post.softwareBrightness != nil || post.softwareContrast != nil {
            let b = Double((post.softwareBrightness ?? 1000) - 1000) / 1000 * 0.5
            let cv = Double(post.softwareContrast ?? 1000)
            let c = cv <= 1000 ? 0.25 + 0.75 * cv / 1000 : 1 + (cv - 1000) / 1000
            ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: b, kCIInputContrastKey: c, kCIInputSaturationKey: 1])
        }
        if let sh = post.sharpen, sh != 1000 {
            let radius = 1.5 * Double(resolution) / 300
            if sh > 1000 {
                ci = ci.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: radius, kCIInputIntensityKey: Double(sh - 1000) / 1000])
            } else {
                let r = radius * Double(1000 - sh) / 1000
                ci = ci.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r]).cropped(to: extent)
            }
        }
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        let out: CGImage?
        if gray {
            out = ctx.createCGImage(ci, from: extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        } else {
            out = ctx.createCGImage(ci, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        guard let out else { throw ImagePipelineError.encode }
        return out
    }

    // MARK: threshold

    /// Black and white from a gray image. 1000 is the middle, 128. `oneBit` gives a 1-bit image, else
    /// 8-bit gray with only 0 and 255.
    private static func threshold(_ image: CGImage, level: Int, rawGray: MappedFile?, oneBit: Bool) throws -> CGImage {
        let cut = UInt8(min(min(max(level, 0), 2000) * 256 / 2000, 255))
        let w = image.width, h = image.height
        // Gray source rows: the mapped page when it is raw 8-bit gray, else a gray redraw of the image.
        var redraw: [UInt8] = []
        let rows: UnsafePointer<UInt8>
        let stride: Int
        if let m = rawGray, image.bytesPerRow * h <= m.size {
            rows = UnsafePointer(m.base.assumingMemoryBound(to: UInt8.self)); stride = image.bytesPerRow
        } else {
            redraw = [UInt8](repeating: 0, count: w * h)
            guard let ctx = CGContext(data: &redraw, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { throw ImagePipelineError.encode }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return try redraw.withUnsafeBufferPointer { buf in
                try cut1(buf.baseAddress!, stride: w, w: w, h: h, cut: cut, oneBit: oneBit)
            }
        }
        return try cut1(rows, stride: stride, w: w, h: h, cut: cut, oneBit: oneBit)
    }

    private static func cut1(_ rows: UnsafePointer<UInt8>, stride: Int, w: Int, h: Int, cut: UInt8, oneBit: Bool) throws -> CGImage {
        let space = CGColorSpaceCreateDeviceGray()
        var data: Data
        let bpc: Int, bpp: Int, bytesPerRow: Int
        if oneBit {
            bytesPerRow = (w + 7) / 8
            bpc = 1; bpp = 1
            data = Data(count: bytesPerRow * h)
            data.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
                for y in 0..<h {
                    let src = rows + y * stride
                    for x in 0..<w where src[x] >= cut {
                        out[y * bytesPerRow + x / 8] |= UInt8(0x80 >> (x % 8))   // 1 is white
                    }
                }
            }
        } else {
            bytesPerRow = w; bpc = 8; bpp = 8
            data = Data(count: w * h)
            data.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
                for y in 0..<h {
                    let src = rows + y * stride
                    for x in 0..<w { out[y * w + x] = src[x] >= cut ? 255 : 0 }
                }
            }
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: bpc, bitsPerPixel: bpp, bytesPerRow: bytesPerRow, space: space,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw ImagePipelineError.encode }
        return img
    }

    // MARK: encode

    private static func encode(_ image: CGImage, as format: ESCLFormat, resolution: Int, to output: URL) throws {
        try? FileManager.default.removeItem(at: output)
        switch format {
        case .pdf:
            var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) / CGFloat(resolution) * 72,
                             height: CGFloat(image.height) / CGFloat(resolution) * 72)
            guard let ctx = CGContext(output as CFURL, mediaBox: &box, nil) else { throw ImagePipelineError.encode }
            ctx.beginPDFPage(nil)
            ctx.draw(image, in: box)
            ctx.endPDFPage()
            ctx.closePDF()
        case .jpeg, .png, .tiff:
            let type = format == .jpeg ? "public.jpeg" : format == .png ? "public.png" : "public.tiff"
            guard let dest = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, 1, nil) else { throw ImagePipelineError.encode }
            var props: [CFString: Any] = [kCGImagePropertyDPIWidth: resolution, kCGImagePropertyDPIHeight: resolution]
            if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw ImagePipelineError.encode }
        }
    }
}
