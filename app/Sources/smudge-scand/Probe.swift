// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import SmudgeKit
import SmudgeScan

private func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); v = true; lock.unlock() }
}

/// Hardware check: one scan with every LEDM request logged to stderr. Ctrl-C cancels the job.
func runProbe(value: @escaping (String) -> String?, flag: (String) -> Bool) -> Never {
    let serial = value("--serial")
    let res = Int(value("--res") ?? "75") ?? 75
    let format = LEDMFormat(rawValue: value("--format") ?? "Jpeg") ?? .jpeg
    let color = value("--color") ?? "Color"
    let brightness = Int(value("--brightness") ?? "1000") ?? 1000
    let contrast = Int(value("--contrast") ?? "1000") ?? 1000
    let outDir = URL(fileURLWithPath: value("--out") ?? ".")
    let tag = value("--tag")
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let cancelled = Flag()
    signal(SIGINT, SIG_IGN)
    let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sig.setEventHandler { err("SIGINT: cancelling"); cancelled.set() }
    sig.resume()

    DispatchQueue.global().async {
        do {
            let caps = try LEDMScanDevice.fetchCaps(serial: serial)
            err("caps: \(caps.model) \(caps.maxWidth)x\(caps.maxHeight) res \(caps.resolutions)")
            let dev = LEDMScanDevice(serial: serial ?? "", caps: caps)
            dev.log = { err($0) }
            let w = Int(value("--width") ?? "") ?? caps.maxWidth
            let h = Int(value("--height") ?? "") ?? caps.maxHeight
            let req = LEDMScanRequest(resolution: res, xStart: 0, yStart: 0, width: w, height: h, format: format,
                                      colorSpace: color, brightness: brightness, contrast: contrast)
            let ext = format == .jpeg ? "jpg" : "raw"
            let name = "page" + (tag.map { "-" + $0 } ?? "") + "." + ext
            let out = outDir.appendingPathComponent(name)
            let t0 = Date()
            let outcome = try dev.scan(req, to: out, isCancelled: { cancelled.value }, onPageReady: { _ in })
            err("outcome: \(outcome) in \(Date().timeIntervalSince(t0))s -> \(out.path)")
            let state = try dev.scannerState()
            err("scanner state after: \(state)")
            exit(0)
        } catch {
            err("probe failed: \(error.localizedDescription)")
            exit(1)
        }
    }
    dispatchMain()
}

/// Registers the scanner Bonjour record for 60 s, for the launchd check.
func runProbeBonjour() -> Never {
    let uuid = ScannerIdentity.uuid(serial: "probe").uuidString
    do {
        let ad = try BonjourAdvert(name: "Smudge Probe", port: 8, txt: ScanTXT.records(name: "Smudge Probe", formats: ["image/jpeg"], uuid: uuid))
        err("registered _uscan._tcp local-only")
        Thread.sleep(forTimeInterval: 60)
        ad.stop()
        exit(0)
    } catch {
        err("\(error)")
        exit(1)
    }
}
