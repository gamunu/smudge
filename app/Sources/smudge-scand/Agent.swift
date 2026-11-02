// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import SmudgeKit
import SmudgeScan

private func log(_ s: String) {
    FileHandle.standardError.write(Data(("\(Date()) \(s)\n").utf8))
}

/// Points stderr at ~/Library/Logs/Smudge/smudge-scand.log. Every logged-in user runs an
/// agent, so a shared path such as /tmp would let one user plant a symlink that another
/// user's agent then writes through.
func redirectLogToUserLibrary() {
    guard let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
    let dir = lib.appendingPathComponent("Logs/Smudge", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fd = open(dir.appendingPathComponent("smudge-scand.log").path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return }
    dup2(fd, STDERR_FILENO)
    Darwin.close(fd)
}

/// Serves every attached scanner to Image Capture while this user owns the console and scanner
/// sharing is on. It holds no USB interface between requests.
final class Agent: @unchecked Sendable {  // mutable state is touched on `queue` only
    static let prefsDomain = "io.github.gamunu.smudge"
    static let sharingKey = "scanSharing"
    static let sharingNotification = "io.github.gamunu.smudge.scanSharingChanged"

    private final class Entry: @unchecked Sendable {  // fields are touched on `queue` only
        let info: USBDeviceInfo
        var caps: LEDMScanCaps?
        var service: ScannerService?
        var starting = false
        init(info: USBDeviceInfo) { self.info = info }
    }

    private let queue = DispatchQueue(label: "scand.agent")
    private var entries: [UInt64: Entry] = [:]
    private var consoleUser = false
    private var sharing = true
    private let activity = ActivityStore()
    private var gate: ConsoleGate?
    private var watcher: DeviceWatcher?

    /// The setting is read from the app's preferences domain, so a change made in Smudge shows up here.
    static func readSharing() -> Bool {
        CFPreferencesAppSynchronize(prefsDomain as CFString)
        let v = CFPreferencesCopyAppValue(sharingKey as CFString, prefsDomain as CFString)
        return (v as? Bool) ?? true
    }

    func run() -> Never {
        queue.sync {
            sharing = Agent.readSharing()
        }
        gate = ConsoleGate { [weak self] isConsole in
            guard let self else { return }
            queue.async { [self] in self.consoleUser = isConsole; self.apply() }
        }
        queue.sync { consoleUser = gate?.isConsoleUser ?? false }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Agent.sharingNotification), object: nil,
                                                            queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.async { [self] in self.sharing = Agent.readSharing(); self.apply() }
        }
        let watcher = DeviceWatcher(onAdd: { [weak self] d in guard let self else { return }; queue.async { [self] in self.add(d) } },
                                    onRemove: { [weak self] id in guard let self else { return }; queue.async { [self] in self.remove(id) } })
        self.watcher = watcher
        watcher.start()
        log("smudge-scand started (console user \(consoleUser), sharing \(sharing))")
        dispatchMain()
    }

    // MARK: devices (all on `queue`)

    private func add(_ info: USBDeviceInfo) {
        guard entries[info.registryID] == nil else { return }
        log("scanner arrived: product \(String(info.product, radix: 16)) serial \(info.serial ?? "none")")
        entries[info.registryID] = Entry(info: info)
        apply()
    }

    private func remove(_ id: UInt64) {
        guard let e = entries.removeValue(forKey: id) else { return }
        log("scanner left: serial \(e.info.serial ?? "none")")
        stop(e)
    }

    private var shouldServe: Bool { consoleUser && sharing }

    private func apply() {
        for e in entries.values {
            if shouldServe {
                start(e)
            } else {
                stopWhenIdle(e)
            }
        }
    }

    private func start(_ e: Entry, attempt: Int = 0) {
        guard e.service == nil, !e.starting, let serial = e.info.serial, !serial.isEmpty else { return }
        e.starting = true
        DispatchQueue.global().async { [self] in
            let result: Result<LEDMScanCaps, Error>
            if let c = queue.sync(execute: { e.caps }) { result = .success(c) } else {
                result = Result { try LEDMScanDevice.fetchCaps(serial: serial) }
            }
            queue.async { [self] in
                e.starting = false
                guard entries[e.info.registryID] === e, shouldServe, e.service == nil else { return }
                switch result {
                case .failure(let err):
                    log("cannot read scanner caps (\(err.localizedDescription)), attempt \(attempt + 1)")
                    if attempt < 4 { queue.asyncAfter(deadline: .now() + 3) { [self] in start(e, attempt: attempt + 1) } }
                case .success(let caps):
                    e.caps = caps
                    serve(e, serial: serial, caps: caps)
                }
            }
        }
    }

    private func serve(_ e: Entry, serial: String, caps: LEDMScanCaps) {
        let same = entries.values.filter { $0.caps?.model == caps.model }.count
        let name = ScannerIdentity.name(model: caps.model, serial: serial, sameModelCount: same)
        let device = LEDMScanDevice(serial: serial, caps: caps)
        let store = activity
        do {
            e.service = try ScannerService(
                serial: serial, device: device, name: name, workDir: scanWorkDir(),
                log: { line in if !line.contains("/ScannerStatus") && !line.contains("/ScannerCapabilities") { log(line) } },
                onActivity: { scanning in store.set(scanning ? .scanning : nil, serial: serial, writer: .scand) },
                blocked: { store.current(serial: serial, from: .app) == .maintenance })
            log("serving \(name) on 127.0.0.1:\(e.service!.port)")
        } catch {
            log("cannot serve \(name): \(error)")
        }
    }

    private func stop(_ e: Entry) {
        guard let svc = e.service else { return }
        e.service = nil
        let serial = e.info.serial ?? ""
        DispatchQueue.global().async { [activity] in
            svc.stop()
            activity.set(nil, serial: serial, writer: .scand)
        }
    }

    /// A scan that is running finishes before the listener goes away.
    private func stopWhenIdle(_ e: Entry) {
        guard let svc = e.service else { return }
        if svc.router.isBusy {
            queue.asyncAfter(deadline: .now() + 2) { [self] in
                if !shouldServe, entries[e.info.registryID] === e { stopWhenIdle(e) }
            }
            return
        }
        log("stopped serving serial \(e.info.serial ?? "none")")
        stop(e)
    }
}
