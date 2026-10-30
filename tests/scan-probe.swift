// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

// ImageCaptureCore client for the scanner bridge: finds a scanner by name, opens a session, selects
// the flatbed, scans once and exits 0 when a file arrives.
//
//   scan-probe --name SUBSTR --res N --mode color|gray|bw --format jpeg|png|tiff|pdf --out DIR
//              [--width W --height H] [--timeout SECONDS] [--cancel-after SECONDS]
//
// Prints one line on success: file=<path> area=<w>x<h> (1/300 inch).
import Foundation
import ImageCaptureCore

setvbuf(stdout, nil, _IOLBF, 0)

func arg(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

func fail(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(code)
}

let wantName = arg("--name") ?? ""
let res = Int(arg("--res") ?? "75") ?? 75
let mode = arg("--mode") ?? "color"
let format = arg("--format") ?? "jpeg"
let outDir = URL(fileURLWithPath: arg("--out") ?? ".")
let timeout = Double(arg("--timeout") ?? "120") ?? 120
let wantW = Int(arg("--width") ?? "")
let wantH = Int(arg("--height") ?? "")

let utiByFormat = ["jpeg": "public.jpeg", "png": "public.png", "tiff": "public.tiff", "pdf": "com.adobe.pdf"]
let documentUTI: String = utiByFormat[format] ?? { fail("bad --format") }()
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

final class Probe: NSObject, ICDeviceBrowserDelegate, ICScannerDeviceDelegate {
    let browser = ICDeviceBrowser()
    var scanner: ICScannerDevice?
    var area = ""
    var scanned: URL?

    func start() {
        browser.delegate = self
        let types: UInt = ICDeviceTypeMask.scanner.rawValue
            | ICDeviceLocationTypeMask.local.rawValue | ICDeviceLocationTypeMask.shared.rawValue
            | ICDeviceLocationTypeMask.bonjour.rawValue | ICDeviceLocationTypeMask.remote.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: types)!
        browser.start()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard scanner == nil, let s = device as? ICScannerDevice, (s.name ?? "").contains(wantName) else { return }
        print("found: \(s.name ?? "?")")
        scanner = s
        s.delegate = self
        s.requestOpenSession()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}
    func didRemove(_ device: ICDevice) { fail("scanner removed") }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error { fail("open session: \(error)") }
    }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    func deviceDidBecomeReady(_ device: ICDevice) {
        guard let s = device as? ICScannerDevice else { return }
        print("ready: units \(s.availableFunctionalUnitTypes)")
        if let unit = (s as AnyObject).value(forKey: "selectedFunctionalUnit") as? ICScannerFunctionalUnitFlatbed {
            configure(s, unit)
        } else {
            s.requestSelect(.flatbed)
        }
    }

    var configured = false

    func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit?, error: Error?) {
        if let error { fail("select flatbed: \(error)") }
        guard let fu = functionalUnit as? ICScannerFunctionalUnitFlatbed else { fail("no flatbed unit selected") }
        configure(scanner, fu)
    }

    func configure(_ scanner: ICScannerDevice, _ fu: ICScannerFunctionalUnitFlatbed) {
        if configured { return }
        configured = true
        fu.measurementUnit = .inches
        guard fu.supportedResolutions.contains(res) else { fail("resolution \(res) not offered: \(fu.supportedResolutions)") }
        fu.resolution = res
        switch mode {
        case "color": fu.pixelDataType = .RGB; fu.bitDepth = .depth8Bits
        case "gray": fu.pixelDataType = .gray; fu.bitDepth = .depth8Bits
        default: fu.pixelDataType = .BW; fu.bitDepth = .depth1Bit
        }
        let max = fu.physicalSize
        let w = wantW.map { Double($0) / 300 } ?? Double(max.width)
        let h = wantH.map { Double($0) / 300 } ?? Double(max.height)
        fu.scanArea = NSRect(x: 0, y: 0, width: w, height: h)
        area = "\(Int((w * 300).rounded()))x\(Int((h * 300).rounded()))"
        scanner.transferMode = .fileBased
        scanner.downloadsDirectory = outDir
        scanner.documentName = "scan-\(res)-\(mode)"
        scanner.documentUTI = documentUTI
        print("unit: res \(fu.supportedResolutions.sorted()) size \(fu.physicalSize) depths \(fu.supportedBitDepths) types \(fu.supportedMeasurementUnits) overview \(fu.canPerformOverviewScan)")
        print("scanning \(res) dpi \(mode) \(format) area \(area)")
        print("after set: area \(fu.scanArea) res \(fu.resolution) pdt \(fu.pixelDataType.rawValue) depth \(fu.bitDepth.rawValue) uti \(scanner.documentUTI ?? "nil") dir \(String(describing: scanner.downloadsDirectory))")
        print("unit state \(fu.state.rawValue) hasOpenSession \(scanner.hasOpenSession)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            print("unit state later \(fu.state.rawValue)")
            if CommandLine.arguments.contains("--overview") { scanner.requestOverviewScan() } else { scanner.requestScan() }
            if let after = arg("--cancel-after").flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                    print("cancelling")
                    scanner.cancelScan()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { print("cancelled"); exit(0) }
                }
            }
        }
        print("requested;")
    }

    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) { scanned = url }

    func scannerDevice(_ scanner: ICScannerDevice, didCompleteOverviewScanWithError error: Error?) { print("overview done: \(String(describing: error))"); exit(error == nil ? 0 : 1) }

    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        if let error { if arg("--cancel-after") != nil { print("cancelled: \(error)"); exit(0) }; fail("scan: \(error)") }
        guard let url = scanned else { fail("scan finished with no file") }
        print("file=\(url.path) area=\(area)")
        exit(0)
    }

    func device(_ device: ICDevice, didEncounterError error: Error?) { print("device error: \(String(describing: error))") }
    func scannerDevice(_ scanner: ICScannerDevice, didReceiveStatusInformation status: [String: Any]) { print("status: \(status)") }

    func scannerDeviceDidBecomeAvailable(_ scanner: ICScannerDevice) {}
}

let probe = Probe()
probe.start()
DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { fail("timeout after \(Int(timeout)) s", 3) }
RunLoop.main.run()
