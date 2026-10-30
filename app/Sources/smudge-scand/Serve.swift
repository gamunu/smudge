// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import SmudgeKit
import SmudgeScan

private func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// One scanner served over loopback eSCL and announced on the local-only Bonjour interface.
final class ScannerService {
    let router: ESCLRouter
    let server: HTTPServer
    let advert: BonjourAdvert
    let serial: String

    init(serial: String, device: ScanDevice, name: String, workDir: URL, log: ((String) -> Void)? = nil,
         onActivity: @escaping @Sendable (Bool) -> Void, blocked: @escaping @Sendable () -> Bool = { false }) throws {
        self.serial = serial
        let uuid = ScannerIdentity.uuid(serial: serial)
        router = ESCLRouter(device: device, name: name, uuid: uuid, serial: serial, tone: .deskJet2300,
                            workDir: workDir, onActivity: onActivity, blocked: blocked)
        server = try HTTPServer(router: router, log: log)
        let formats = ESCLCaps.formats(for: device.caps).map(\.rawValue)
        do {
            advert = try BonjourAdvert(name: name, port: server.port,
                                       txt: ScanTXT.records(name: name, formats: formats, uuid: uuid.uuidString.lowercased()))
        } catch {
            server.stop()
            throw error
        }
    }

    var port: UInt16 { server.port }

    func stop() {
        advert.stop()
        server.stop()
        router.shutdown()
    }
}

func scanWorkDir() -> URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appendingPathComponent("Smudge/scan", isDirectory: true)
}

/// `--serve --serial S`: one printer, no device watcher.
func runServe(serial: String?, demo: Bool, demoDelay: Double = 1) -> Never {
    do {
        let device: ScanDevice
        let name: String
        let id: String
        if demo {
            device = DemoScanDevice(delay: demoDelay)
            name = "Smudge Demo Scanner"
            id = "demo"
        } else {
            let caps = try LEDMScanDevice.fetchCaps(serial: serial)
            let dev = LEDMScanDevice(serial: serial ?? "", caps: caps)
            dev.log = { err($0) }
            device = dev
            name = caps.model
            id = serial ?? "only"
        }
        let svc = try ScannerService(serial: id, device: device, name: name, workDir: scanWorkDir(), log: { err($0) },
                                     onActivity: { err("activity: \($0 ? "scanning" : "idle")") })
        err("serving \(name) on 127.0.0.1:\(svc.port)")
        withExtendedLifetime(svc) { dispatchMain() }
    } catch {
        err("serve failed: \(error)")
        exit(1)
    }
}
