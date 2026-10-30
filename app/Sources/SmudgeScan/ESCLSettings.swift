// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

public enum ESCLSettingsError: Error, Equatable {
    case resolution(Int), region, colorMode, format, inputSource
}

/// A scan request as Image Capture sends it. Geometry is in 1/300 inch.
public struct ESCLScanSettings: Equatable, Sendable {
    public var resolution: Int
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var colorMode: ESCLColorMode
    public var format: ESCLFormat
    public var brightness: Int?
    public var contrast: Int?
    public var sharpen: Int?
    public var threshold: Int?
    public var intent: String?
    public var inputSource: String

    public init(resolution: Int, x: Int, y: Int, width: Int, height: Int, colorMode: ESCLColorMode, format: ESCLFormat,
                brightness: Int? = nil, contrast: Int? = nil, sharpen: Int? = nil, threshold: Int? = nil,
                intent: String? = nil, inputSource: String = "Platen") {
        self.resolution = resolution
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.colorMode = colorMode
        self.format = format
        self.brightness = brightness
        self.contrast = contrast
        self.sharpen = sharpen
        self.threshold = threshold
        self.intent = intent
        self.inputSource = inputSource
    }

    /// nil when the document is not an eSCL ScanSettings or uses region units other than 1/300 inch.
    /// Missing fields take defaults: 300 dpi, color, JPEG, and a zero region that means the whole glass.
    public static func parse(_ xml: Data) -> ESCLScanSettings? {
        var s = ESCLScanSettings(resolution: 300, x: 0, y: 0, width: 0, height: 0, colorMode: .rgb24, format: .jpeg)
        var sawRoot = false
        var badUnits = false
        var formatExt: ESCLFormat?
        var formatPlain: ESCLFormat?
        let ok = XMLPath.walk(xml, start: { path, _ in
            if path.count == 1 { sawRoot = path[0] == "ScanSettings" }
        }, end: { path, text in
            guard let name = path.last else { return }
            let inRegion = path.contains("ScanRegion")
            let n = Int(text)
            switch name {
            case "Intent": s.intent = text
            case "ContentRegionUnits": if !text.contains("ThreeHundredths") { badUnits = true }
            case "Width": if inRegion, let n { s.width = n }
            case "Height": if inRegion, let n { s.height = n }
            case "XOffset": if inRegion, let n { s.x = n }
            case "YOffset": if inRegion, let n { s.y = n }
            case "DocumentFormat": formatPlain = ESCLFormat(rawValue: text) ?? formatPlain
            case "DocumentFormatExt": formatExt = ESCLFormat(rawValue: text) ?? formatExt
            case "InputSource": s.inputSource = text
            case "ColorMode": if let m = ESCLColorMode(rawValue: text) { s.colorMode = m }
            case "XResolution": if let n { s.resolution = n }
            case "Brightness": s.brightness = n
            case "Contrast": s.contrast = n
            case "Sharpen": s.sharpen = n
            case "Threshold": s.threshold = n
            default: break
            }
        })
        guard ok, sawRoot, !badUnits else { return nil }
        if let f = formatExt ?? formatPlain { s.format = f }
        return s
    }

    /// Checks the settings against what the scanner can do and returns the copy to scan with.
    /// A region that overshoots the glass by up to 2 units is trimmed to the edge. A bigger overshoot,
    /// a negative offset or a side below the minimum is `.region`. No region means the whole glass.
    public func validated(against caps: LEDMScanCaps) throws -> ESCLScanSettings {
        var r = self
        guard inputSource == "Platen" else { throw ESCLSettingsError.inputSource }
        guard caps.resolutions.contains(resolution) else { throw ESCLSettingsError.resolution(resolution) }
        guard ESCLCaps.colorModes(for: caps).contains(colorMode) else { throw ESCLSettingsError.colorMode }
        guard ESCLCaps.formats(for: caps).contains(format) else { throw ESCLSettingsError.format }

        if r.width == 0, r.height == 0, r.x == 0, r.y == 0 { r.width = caps.maxWidth; r.height = caps.maxHeight }
        guard r.x >= 0, r.y >= 0, r.width > 0, r.height > 0 else { throw ESCLSettingsError.region }
        let tolerance = 2
        let overW = r.x + r.width - caps.maxWidth
        let overH = r.y + r.height - caps.maxHeight
        guard overW <= tolerance, overH <= tolerance else { throw ESCLSettingsError.region }
        if overW > 0 { r.width -= overW }
        if overH > 0 { r.height -= overH }
        guard r.width >= caps.minWidth, r.height >= caps.minHeight else { throw ESCLSettingsError.region }

        func clamp(_ v: Int?) -> Int? { v.map { min(max($0, 0), 2000) } }
        r.brightness = clamp(brightness)
        r.contrast = clamp(contrast)
        r.sharpen = clamp(sharpen)
        r.threshold = clamp(threshold)
        return r
    }
}
