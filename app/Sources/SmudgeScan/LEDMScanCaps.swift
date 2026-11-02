// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

public enum LEDMColorType: String, Sendable { case k1 = "K1", gray8 = "Gray8", color8 = "Color8" }
public enum LEDMFormat: String, Sendable { case raw = "Raw", jpeg = "Jpeg" }

/// What the scanner reports at /Scan/ScanCaps. Geometry is in 1/300 inch.
public struct LEDMScanCaps: Equatable, Sendable {
    public var model: String
    public var minWidth: Int
    public var minHeight: Int
    public var maxWidth: Int
    public var maxHeight: Int
    public var resolutions: [Int]
    public var maxOptical: Int
    public var formats: [LEDMColorType: Set<LEDMFormat>]
    public var hasADF: Bool

    public init(model: String, minWidth: Int, minHeight: Int, maxWidth: Int, maxHeight: Int,
                resolutions: [Int], maxOptical: Int, formats: [LEDMColorType: Set<LEDMFormat>], hasADF: Bool) {
        self.model = model
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.resolutions = resolutions
        self.maxOptical = maxOptical
        self.formats = formats
        self.hasADF = hasADF
    }

    /// Reads the platen section. Resolutions with different X and Y are dropped. An ADF section
    /// sets `hasADF` and is otherwise ignored. nil when there is no platen area.
    public static func parse(_ xml: Data) -> LEDMScanCaps? {
        var model = ""
        var ints: [String: Int] = [:]
        var entryType: LEDMColorType?
        var entryFormats: Set<LEDMFormat> = []
        var formats: [LEDMColorType: Set<LEDMFormat>] = [:]
        var resX = 0, resY = 0
        var resolutions: Set<Int> = []
        var adf = false

        let ok = XMLPath.walk(xml, start: { path, _ in
            if path.last == "ColorEntry" { entryType = nil; entryFormats = [] }
            if path.last == "Resolution" { resX = 0; resY = 0 }
            if path.contains(where: { $0.lowercased() == "adf" }) { adf = true }
        }, end: { path, text in
            guard let name = path.last else { return }
            if path.contains(where: { $0.lowercased() == "adf" }) { return }
            switch name {
            case "ModelName": if path.contains("DeviceCaps") { model = text }
            case "ColorType": if path.suffix(2) == ["ColorEntry", "ColorType"] { entryType = LEDMColorType(rawValue: text) }
            case "Format": if path.suffix(3) == ["ColorEntry", "Formats", "Format"], let f = LEDMFormat(rawValue: text) { entryFormats.insert(f) }
            case "ColorEntry": if let t = entryType { formats[t] = entryFormats }
            case "XResolution": if path.contains("Resolution") { resX = Int(text) ?? 0 }
            case "YResolution": if path.contains("Resolution") { resY = Int(text) ?? 0 }
            case "Resolution": if resX > 0, resX == resY { resolutions.insert(resX) }
            case "MinWidth", "MinHeight", "MaxWidth", "MaxHeight", "MaxOpticalXResolution":
                if path.contains("Platen") { ints[name] = Int(text) }
            default: break
            }
        })
        guard ok, let maxW = ints["MaxWidth"], let maxH = ints["MaxHeight"], maxW > 0, maxH > 0 else { return nil }
        return LEDMScanCaps(model: model, minWidth: ints["MinWidth"] ?? 1, minHeight: ints["MinHeight"] ?? 1,
                            maxWidth: maxW, maxHeight: maxH, resolutions: resolutions.sorted(),
                            maxOptical: ints["MaxOpticalXResolution"] ?? (resolutions.max() ?? 0),
                            formats: formats, hasADF: adf)
    }
}
