// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import XCTest
@testable import SmudgeScan

final class ESCLTests: XCTestCase {
    private func caps() throws -> LEDMScanCaps {
        try XCTUnwrap(LEDMScanCaps.parse(Data(ScanFixtures.scanCaps2336.utf8)))
    }

    func testCapsAdvertiseWhatSpikeNeeded() throws {
        let x = ESCLCaps.xml(caps: try caps(), name: "DeskJet 2300",
                             uuid: UUID(uuidString: "4E2F6A1C-2336-4000-8000-00000000A1B2")!, serial: "CN171232SB")
        for needle in ["<scan:MaxPhysicalWidth>2550</scan:MaxPhysicalWidth>", "<scan:MaxPhysicalHeight>3508</scan:MaxPhysicalHeight>",
                       "<scan:ColorSpace>sRGB</scan:ColorSpace>", "<scan:ColorMode>BlackAndWhite1</scan:ColorMode>",
                       "<scan:ColorMode>RGB24</scan:ColorMode>", "<scan:XResolution>1200</scan:XResolution>",
                       "<scan:BrightnessSupport>", "<scan:ThresholdSupport>", "<pwg:DocumentFormat>application/pdf</pwg:DocumentFormat>"] {
            XCTAssertTrue(x.contains(needle), needle)
        }
        XCTAssertNotNil(try? XMLDocument(xmlString: x))
    }

    func testParsesImageCaptureDefaultSettings() throws {
        // Verbatim from the spike log.
        let xml = #"<?xml version="1.0" encoding="UTF-8"?><scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm"><pwg:Version>2.0</pwg:Version><scan:Intent>TextAndGraphic</scan:Intent><pwg:ScanRegions pwg:MustHonor="true"><pwg:ScanRegion><pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits><pwg:Width>2480</pwg:Width><pwg:Height>3508</pwg:Height><pwg:XOffset>0</pwg:XOffset><pwg:YOffset>0</pwg:YOffset></pwg:ScanRegion></pwg:ScanRegions><pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat><pwg:InputSource>Platen</pwg:InputSource><scan:ColorMode>RGB24</scan:ColorMode><scan:XResolution>300</scan:XResolution><scan:YResolution>300</scan:YResolution></scan:ScanSettings>"#
        let s = try XCTUnwrap(ESCLScanSettings.parse(Data(xml.utf8)))
        XCTAssertEqual([s.resolution, s.x, s.y, s.width, s.height], [300, 0, 0, 2480, 3508])
        XCTAssertEqual(s.colorMode, .rgb24); XCTAssertEqual(s.format, .jpeg); XCTAssertEqual(s.intent, "TextAndGraphic")
    }

    func testParsesAdjustmentsAndRejectsJunk() throws {
        let xml = """
        <scan:ScanSettings xmlns:scan="x" xmlns:pwg="y"><scan:Brightness>1500</scan:Brightness><scan:Contrast>500</scan:Contrast>\
        <scan:Sharpen>1200</scan:Sharpen><scan:Threshold>900</scan:Threshold><scan:ColorMode>BlackAndWhite1</scan:ColorMode>\
        <pwg:DocumentFormat>application/pdf</pwg:DocumentFormat></scan:ScanSettings>
        """
        let s = try XCTUnwrap(ESCLScanSettings.parse(Data(xml.utf8)))
        XCTAssertEqual([s.brightness, s.contrast, s.sharpen, s.threshold], [1500, 500, 1200, 900])
        XCTAssertEqual(s.colorMode, .blackAndWhite1); XCTAssertEqual(s.format, .pdf)
        XCTAssertNil(ESCLScanSettings.parse(Data("<junk/>".utf8)))
        XCTAssertNil(ESCLScanSettings.parse(Data("not xml".utf8)))
    }

    func testValidationClampsOneUnitOvershootAndRejectsRealOverflow() throws {
        let caps = try caps()
        var s = ESCLScanSettings(resolution: 300, x: 70, y: 0, width: 2481, height: 3508, colorMode: .rgb24, format: .jpeg)
        XCTAssertEqual(try s.validated(against: caps).width, 2480)              // 70 + 2481 = 2551 -> clamped
        s.width = 2600
        XCTAssertThrowsError(try s.validated(against: caps)) { XCTAssertEqual($0 as? ESCLSettingsError, .region) }
        s = ESCLScanSettings(resolution: 250, x: 0, y: 0, width: 100, height: 100, colorMode: .rgb24, format: .jpeg)
        XCTAssertThrowsError(try s.validated(against: caps)) { XCTAssertEqual($0 as? ESCLSettingsError, .resolution(250)) }
    }

    func testValidationEdges() throws {
        let caps = try caps()
        let ok = ESCLScanSettings(resolution: 300, x: 0, y: 0, width: 2480, height: 3508, colorMode: .rgb24, format: .jpeg)
        XCTAssertEqual(try ok.validated(against: caps), ok)                       // A4 width inside 2550
        var s = ok; s.height = 3510
        XCTAssertEqual(try s.validated(against: caps).height, 3508)               // 2 over is trimmed
        s.height = 3511
        XCTAssertThrowsError(try s.validated(against: caps))                      // 3 over is rejected
        s = ok; s.width = 4
        XCTAssertThrowsError(try s.validated(against: caps)) { XCTAssertEqual($0 as? ESCLSettingsError, .region) }
        s = ok; s.x = -1
        XCTAssertThrowsError(try s.validated(against: caps))
        s = ok; s.inputSource = "Feeder"
        XCTAssertThrowsError(try s.validated(against: caps)) { XCTAssertEqual($0 as? ESCLSettingsError, .inputSource) }
        s = ok; s.width = 0; s.height = 0
        let full = try s.validated(against: caps)
        XCTAssertEqual([full.width, full.height], [2550, 3508])                   // no region means the whole glass
    }

    func testStatusListsJobs() {
        let j = ESCLJobInfo(id: 2, uuid: UUID(), age: 1, imagesCompleted: 0, imagesToTransfer: 1, state: .processing)
        let x = ESCLStatus.xml(state: "Processing", jobs: [j])
        XCTAssertTrue(x.contains("<pwg:JobUri>/eSCL/ScanJobs/2</pwg:JobUri>"))
        XCTAssertTrue(x.contains("<pwg:JobState>Processing</pwg:JobState>"))
        XCTAssertTrue(x.contains("<pwg:ImagesToTransfer>1</pwg:ImagesToTransfer>"))
        XCTAssertTrue(x.contains("<pwg:JobStateReason>JobScanning</pwg:JobStateReason>"))
        XCTAssertNotNil(try? XMLDocument(xmlString: x))
    }
}
