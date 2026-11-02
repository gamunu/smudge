// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

public enum ESCLColorMode: String, Sendable { case rgb24 = "RGB24", grayscale8 = "Grayscale8", blackAndWhite1 = "BlackAndWhite1" }
public enum ESCLFormat: String, CaseIterable, Sendable {
    case jpeg = "image/jpeg", png = "image/png", tiff = "image/tiff", pdf = "application/pdf"
}

public enum ESCLCaps {
    static let ns = "xmlns:scan=\"http://schemas.hp.com/imaging/escl/2011/05/03\" xmlns:pwg=\"http://www.pwg.org/schemas/2010/12/sm\""

    /// Color modes the scanner can serve. Black and white comes from a K1 or gray scan.
    public static func colorModes(for caps: LEDMScanCaps) -> [ESCLColorMode] {
        var out: [ESCLColorMode] = []
        if caps.formats[.color8] != nil { out.append(.rgb24) }
        if caps.formats[.gray8] != nil { out.append(.grayscale8) }
        if caps.formats[.k1] != nil { out.append(.blackAndWhite1) }
        return out
    }

    /// JPEG needs a Jpeg-capable color type. PNG and TIFF are encoded from Raw. PDF wraps either.
    public static func formats(for caps: LEDMScanCaps) -> [ESCLFormat] {
        let all = caps.formats.values.flatMap { $0 }
        let jpeg = all.contains(.jpeg), raw = all.contains(.raw)
        var out: [ESCLFormat] = []
        if jpeg { out.append(.jpeg) }
        if raw { out.append(contentsOf: [.png, .tiff]) }
        if jpeg || raw { out.append(.pdf) }
        return out
    }

    private static func support(_ tag: String) -> String {
        "<scan:\(tag)><scan:Min>0</scan:Min><scan:Max>2000</scan:Max><scan:Normal>1000</scan:Normal><scan:Step>1</scan:Step></scan:\(tag)>"
    }

    public static func xml(caps: LEDMScanCaps, name: String, uuid: UUID, serial: String) -> String {
        let modes = colorModes(for: caps).map { "<scan:ColorMode>\($0.rawValue)</scan:ColorMode>" }.joined()
        let formats = formats(for: caps).map {
            "<pwg:DocumentFormat>\($0.rawValue)</pwg:DocumentFormat><scan:DocumentFormatExt>\($0.rawValue)</scan:DocumentFormatExt>"
        }.joined()
        let res = caps.resolutions.map {
            "<scan:DiscreteResolution><scan:XResolution>\($0)</scan:XResolution><scan:YResolution>\($0)</scan:YResolution></scan:DiscreteResolution>"
        }.joined()
        let intents = ["Document", "TextAndGraphic", "Photo", "Preview"].map { "<scan:Intent>\($0)</scan:Intent>" }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        + "<scan:ScannerCapabilities \(ns)>"
        + "<pwg:Version>2.63</pwg:Version>"
        + "<pwg:MakeAndModel>\(XMLText.escape(name))</pwg:MakeAndModel>"
        + "<pwg:SerialNumber>\(XMLText.escape(serial))</pwg:SerialNumber>"
        + "<scan:UUID>\(uuid.uuidString.lowercased())</scan:UUID>"
        + "<scan:Platen><scan:PlatenInputCaps>"
        + "<scan:MinWidth>\(caps.minWidth)</scan:MinWidth><scan:MaxWidth>\(caps.maxWidth)</scan:MaxWidth>"
        + "<scan:MinHeight>\(caps.minHeight)</scan:MinHeight><scan:MaxHeight>\(caps.maxHeight)</scan:MaxHeight>"
        + "<scan:MaxPhysicalWidth>\(caps.maxWidth)</scan:MaxPhysicalWidth><scan:MaxPhysicalHeight>\(caps.maxHeight)</scan:MaxPhysicalHeight>"
        + "<scan:MaxScanRegions>1</scan:MaxScanRegions>"
        + "<scan:SettingProfiles><scan:SettingProfile>"
        + "<scan:ColorModes>\(modes)</scan:ColorModes>"
        + "<scan:DocumentFormats>\(formats)</scan:DocumentFormats>"
        + "<scan:SupportedResolutions><scan:DiscreteResolutions>\(res)</scan:DiscreteResolutions></scan:SupportedResolutions>"
        + "<scan:ColorSpaces><scan:ColorSpace>sRGB</scan:ColorSpace></scan:ColorSpaces>"
        + "</scan:SettingProfile></scan:SettingProfiles>"
        + "<scan:SupportedIntents>\(intents)</scan:SupportedIntents>"
        + "<scan:MaxOpticalXResolution>\(caps.maxOptical)</scan:MaxOpticalXResolution>"
        + "<scan:MaxOpticalYResolution>\(caps.maxOptical)</scan:MaxOpticalYResolution>"
        + support("BrightnessSupport") + support("ContrastSupport") + support("SharpenSupport") + support("ThresholdSupport")
        + "</scan:PlatenInputCaps></scan:Platen>"
        + "</scan:ScannerCapabilities>"
    }
}
