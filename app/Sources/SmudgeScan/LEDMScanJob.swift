// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

/// One scan job in the LEDM ScanSettings format. Field order follows HPLIP's bb_ledm.c.
public struct LEDMScanRequest: Equatable, Sendable {
    public var resolution: Int
    public var xStart: Int
    public var yStart: Int
    public var width: Int
    public var height: Int
    public var format: LEDMFormat
    /// "Color" or "Gray".
    public var colorSpace: String
    public var brightness: Int
    public var contrast: Int

    public init(resolution: Int, xStart: Int, yStart: Int, width: Int, height: Int, format: LEDMFormat,
                colorSpace: String, brightness: Int, contrast: Int) {
        self.resolution = resolution
        self.xStart = xStart
        self.yStart = yStart
        self.width = width
        self.height = height
        self.format = format
        self.colorSpace = colorSpace
        self.brightness = brightness
        self.contrast = contrast
    }

    public var xml: String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        + "<ScanSettings xmlns=\"http://www.hp.com/schemas/imaging/con/cnx/scan/2008/08/19\">"
        + "<XResolution>\(resolution)</XResolution><YResolution>\(resolution)</YResolution>"
        + "<XStart>\(xStart)</XStart><Width>\(width)</Width><YStart>\(yStart)</YStart><Height>\(height)</Height>"
        + "<Format>\(format.rawValue)</Format><CompressionQFactor>15</CompressionQFactor>"
        + "<ColorSpace>\(colorSpace)</ColorSpace><BitDepth>8</BitDepth>"
        + "<InputSource>Platen</InputSource><InputSourceType>Platen</InputSourceType>"
        + "<GrayRendering>NTSC</GrayRendering>"
        + "<ToneMap><Gamma>0</Gamma><Brightness>\(brightness)</Brightness><Contrast>\(contrast)</Contrast>"
        + "<Highlite>0</Highlite><Shadow>0</Shadow></ToneMap>"
        + "<ContentType>Photo</ContentType></ScanSettings>"
    }
}

public enum LEDMScanJob {
    /// Body of the PUT that cancels a job.
    public static let cancelXML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        + "<j:Job xmlns:j=\"http://www.hp.com/schemas/imaging/con/ledm/jobs/2009/04/30\" "
        + "xmlns:dd=\"http://www.hp.com/schemas/imaging/con/dictionaries/1.0/\" "
        + "xmlns:fax=\"http://www.hp.com/schemas/imaging/con/fax/2008/06/13\" "
        + "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" "
        + "xsi:schemaLocation=\"http://www.hp.com/schemas/imaging/con/ledm/jobs/2009/04/30 ../schemas/Jobs.xsd\">"
        + "<j:JobState>Canceled</j:JobState></j:Job>"
}

/// The parts of a job document the bridge acts on.
public struct LEDMJobSnapshot: Equatable, Sendable {
    public var jobState: String?
    public var pageState: String?
    public var binaryURL: String?
    public var hasPreScanPage: Bool
    /// Size of the page the printer is about to send, from the job document once the page is ready.
    public var imageWidth: Int?
    public var imageHeight: Int?
    public var bytesPerLine: Int?

    public init(jobState: String? = nil, pageState: String? = nil, binaryURL: String? = nil, hasPreScanPage: Bool = false,
                imageWidth: Int? = nil, imageHeight: Int? = nil, bytesPerLine: Int? = nil) {
        self.jobState = jobState
        self.pageState = pageState
        self.binaryURL = binaryURL
        self.hasPreScanPage = hasPreScanPage
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.bytesPerLine = bytesPerLine
    }

    /// The page size when the document gives all three values.
    public var geometry: PageGeometry? {
        guard let imageWidth, let imageHeight, let bytesPerLine else { return nil }
        return PageGeometry(width: imageWidth, height: imageHeight, bytesPerLine: bytesPerLine)
    }

    public static func parse(_ xml: Data) -> LEDMJobSnapshot {
        var s = LEDMJobSnapshot()
        XMLPath.walk(xml, start: { path, _ in
            if path.last == "PreScanPage" { s.hasPreScanPage = true }
        }, end: { path, text in
            switch path.last {
            case "JobState": if s.jobState == nil { s.jobState = text }
            case "PageState": if s.pageState == nil { s.pageState = text }
            case "BinaryURL": if s.binaryURL == nil { s.binaryURL = text }
            case "ImageWidth": if s.imageWidth == nil { s.imageWidth = Int(text) }
            case "ImageHeight": if s.imageHeight == nil { s.imageHeight = Int(text) }
            case "BytesPerLine": if s.bytesPerLine == nil { s.bytesPerLine = Int(text) }
            default: break
            }
        })
        return s
    }
}

/// What to do after one poll of a running LEDM scan job.
public enum LEDMJobStep: Equatable, Sendable {
    case wait
    case upload(String)
    case finished(ScanOutcome)

    /// A job document without a page yet means the printer has not started, so keep polling.
    /// The job only ends on a page or job state that says so.
    public static func next(_ s: LEDMJobSnapshot) -> LEDMJobStep {
        switch s.pageState {
        case "CanceledByDevice": return .finished(.canceledByDevice)
        case "CanceledByClient": return .finished(.canceledByClient)
        case "ReadyToUpload": return s.binaryURL.map { .upload($0) } ?? .wait
        default: break
        }
        switch s.jobState {
        case "Completed": return .finished(.noDocument)
        case "Canceled", "Aborted": return .finished(.canceledByDevice)
        default: return .wait
        }
    }
}

public enum LEDMScanStatus {
    /// "Idle", "BusyWithScanJob" and so on, from /Scan/Status.
    public static func scannerState(_ xml: Data) -> String? {
        var state: String?
        XMLPath.walk(xml) { path, text in
            if path.last == "ScannerState", state == nil { state = text }
        }
        return state
    }
}
