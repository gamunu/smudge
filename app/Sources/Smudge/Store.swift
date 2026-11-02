// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import SmudgeKit
import SwiftUI
import UserNotifications
import Combine

@MainActor
final class StatusStore: ObservableObject {
    @Published var printers: [PrinterInfo] = []
    /// Queue name of the selected printer, remembered across launches. Empty until a queue is found.
    @Published var selected: String = UserDefaults.standard.string(forKey: "printer") ?? "" {
        didSet {
            guard selected != oldValue else { return }
            UserDefaults.standard.set(selected, forKey: "printer")
            previousJobStates = [:]
            resetPrinterState()
            Task { await refresh() }
        }
    }
    /// USB connection per queue name. A queue that is not USB, or has no serial, has no entry.
    @Published var connection: [String: Bool] = [:]
    /// The selected printer's scanner, read on each poll.
    @Published var scanner: ScannerState = .none
    /// Whether the selected printer speaks LEDM over USB.
    @Published var ledmSupport: LEDMSupport = .unknown
    private var currentSerial: String?
    private var deviceOpen = false
    @Published var status: PrinterStatus?
    @Published var usbPresent: Bool?
    @Published var jobs: [PrintJob] = []
    @Published var actionMessage: String?
    /// LEDM status categories read over USB, nil when not read yet.
    @Published var ledmCategories: [String]?
    /// True when CUPS says "processing" but has had no active job for a while.
    @Published var queueStuck = false
    private var stuckRule = StuckQueueRule()
    private var ledmInFlight = false
    private var lastLedmFetch = Date.distantPast
    @Published var ink: InkReport?
    @Published var inkError: String?
    @Published var inkLoading = false
    let maint = MaintenanceController()
    private var maintSink: AnyCancellable?

    /// Name shown for a queue: underscores become spaces.
    static func displayName(_ queue: String) -> String { queue.replacingOccurrences(of: "_", with: " ") }
    var displayName: String { Self.displayName(selected) }
    var selectedInfo: PrinterInfo? { printers.first { $0.name == selected } }

    /// Forgets everything read from the previous printer.
    private func resetPrinterState() {
        ink = nil
        inkError = nil
        ledmCategories = nil
        ledmSupport = .unknown
        status = nil
        usbPresent = nil
        scanner = .none
        jobs = []
        queueStuck = false
        stuckRule = StuckQueueRule()
        lastInkFetch = .distantPast
        lastLedmFetch = .distantPast
        closeDevice()
    }

    /// Closes every LEDM client and detaches the maintenance controller.
    private func closeDevice() {
        LEDMClients.shared.dropAll()
        currentSerial = nil
        deviceOpen = false
        maint.configure(client: nil)
    }

    /// Called after each CUPS read. Opens the LEDM client for the selected printer, and closes it when
    /// the printer is unplugged. Clients for other printers are closed.
    private func updateDevice() {
        guard let uri = status?.deviceURI, !uri.isEmpty else { return }
        guard DeviceURI.isUSB(uri) else {
            ledmSupport = .unavailable(LEDMSupport.noInkReason)
            if deviceOpen { closeDevice() }
            return
        }
        if usbPresent == false {
            // Unplugged: close the client and probe again when it comes back.
            if deviceOpen { closeDevice() }
            ledmSupport = .unknown
            return
        }
        let serial = DeviceURI.serial(uri)
        if !deviceOpen || serial != currentSerial {
            closeDevice()
            currentSerial = serial
            deviceOpen = true
            LEDMClients.shared.keepOnly(serial)
            maint.configure(client: LEDMClients.shared.client(for: serial))
            Task { await refreshInk(force: true) }   // first contact: read ink and capabilities now
        }
    }

    init() {
        // Views read maint.cancelling and maint.cancelOutcome through the store.
        maintSink = maint.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    static let defaultPollSeconds = 3.0
    static let defaultInkSeconds = 60.0
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "notificationsEnabled": true, "showMenuBar": true, ScannerState.sharingKey: true,
            "pollSeconds": defaultPollSeconds, "inkSeconds": defaultInkSeconds,
        ])
    }
    private static func seconds(_ key: String, _ fallback: Double) -> Double {
        let v = UserDefaults.standard.double(forKey: key)
        return v >= 1 ? v : fallback
    }

    private var lastInkFetch = Date.distantPast
    private var inkInFlight = false

    private var previousJobStates: [Int: Int] = [:]
    private var pollCount = 0
    private var started = false
    private let notifier = Notifier()

    var reasonLines: [String] { StatusText.describe(all: status?.reasons ?? []) }
    var hasProblem: Bool {
        guard let s = status else { return false }
        return s.error != nil || s.stateCode == 5 || s.reasons.contains(where: StatusText.isProblem)
            || usbPresent == false
    }

    var iconName: String {
        if hasProblem { return "exclamationmark.triangle.fill" }
        if scanner == .scanning { return "scanner.fill" }
        if isBusy { return "printer.fill" }
        return "printer"
    }

    func start() {
        guard !started, !PreviewMode.isActive else { return }
        started = true
        StatusStore.registerDefaults()
        if UserDefaults.standard.bool(forKey: "notificationsEnabled") { notifier.requestAuthorization() }
        Task { [weak self] in
            while let self {
                await self.refresh()
                try? await Task.sleep(for: .seconds(StatusStore.seconds("pollSeconds", StatusStore.defaultPollSeconds)))
            }
        }
        Task { [weak self] in
            while let self {
                await self.refreshInk()
                try? await Task.sleep(for: .seconds(StatusStore.seconds("inkSeconds", StatusStore.defaultInkSeconds)))
            }
        }
    }

    /// Why maintenance is unavailable, nil when it can start.
    var maintenanceBlockReason: String? {
        if PreviewMode.isActive { return nil }
        if usbPresent == false { return "The printer is not connected over USB." }
        if case .unavailable(let why) = ledmSupport { return "\(why), so maintenance is not available." }
        if scanner == .scanning { return "The scanner is in use. Wait for the scan to finish." }
        if maint.isBusy { return "A maintenance job is running." }
        if jobs.contains(where: \.isActive) { return "A print job is active. Wait for it to finish or cancel it." }
        if isCalibrating { return Self.calibratingNote }
        if isBusy { return "The printer is busy printing." }
        return nil
    }
    var canMaintain: Bool { maintenanceBlockReason == nil }

    var activeJob: PrintJob? { jobs.first(where: \.isActive) }

    /// The job card's line when no print job is active. The printer reports itself busy while it
    /// scans, and that is not printing.
    var idleJobText: String {
        isBusy && scanner != .scanning ? "The printer is working." : "Nothing is printing."
    }

    /// The one busy rule. Busy means CUPS has an active job (pending, held, processing) or the
    /// printer itself reports processing or calibrating. The CUPS printer-state alone does not
    /// count: it can stay at "processing" after the job is gone.
    var isBusy: Bool {
        if activeJob != nil { return true }
        if let c = ledmCategories, Maintenance.isBusy(c) { return true }
        return false
    }

    enum Health { case ready, scanning, printing, attention, disconnected }

    var health: Health {
        guard let s = status else { return .disconnected }
        if usbPresent == false || s.error != nil { return .disconnected }
        if s.stateCode == 5 || s.reasons.contains(where: StatusText.isProblem) { return .attention }
        if let ink = ink, ink.cartridges.contains(where: { $0.state == .empty || $0.state == .missing }) { return .attention }
        if scanner == .scanning { return .scanning }
        if isBusy { return .printing }
        return .ready
    }

    var healthTitle: String {
        switch health {
        case .ready: return "Ready"
        case .scanning: return "Scanning"
        case .printing: return isCalibrating && activeJob == nil ? "Aligning" : "Printing"
        case .attention: return "Needs attention"
        case .disconnected: return "Disconnected"
        }
    }

    static let stuckNote = "The printer looks busy, but nothing is printing."
    static let calibratingNote = "The printer is lining up its print heads. If it asks for the page to be scanned, put it face down on the scanner glass and press the Color Copy button. To stop, press the Cancel (X) button on the printer."

    /// The printer reports an alignment in progress (LEDM "calibrating").
    var isCalibrating: Bool { ledmCategories?.contains("calibrating") ?? false }

    /// Show "Cancel alignment": the printer is calibrating and CUPS has no job.
    var canCancelAlignment: Bool { isCalibrating && activeJob == nil && !maint.cancelling }

    func cancelAlignment() {
        Task {
            await maint.cancelPrinterJob()
            lastLedmFetch = .distantPast
            await refresh()
        }
    }

    /// Plain-language reasons behind the current state.
    var healthDetails: [String] {
        var out: [String] = []
        guard let s = status else { return ["Reading the printer state"] }
        if usbPresent == false { out.append("The USB cable is unplugged or the printer is off.") }
        if let e = s.error { out.append(e) }
        if s.stateCode == 5 { out.append("Printing is paused.") }
        if isCalibrating && activeJob == nil { out.append(Self.calibratingNote) }
        out += reasonLines
        if let ink = ink {
            for c in ink.cartridges where c.state == .empty || c.state == .missing || c.state == .veryLow || c.state == .low {
                out.append("\(c.name) cartridge: \(c.state.text.lowercased())")
            }
        }
        if queueStuck { out.append(StatusStore.stuckNote) }
        else if !s.message.isEmpty && s.stateCode != 3 && !(s.stateCode == 4 && !isBusy) { out.append(s.message) }
        if out.isEmpty {
            switch health {
            case .ready: out.append("The printer is idle and can take a job.")
            case .scanning: out.append("The scanner is in use.")
            case .printing: out.append(activeJob.map { "Printing \($0.title)" } ?? "The printer is working.")
            default: break
            }
        }
        return out
    }

    /// Reads ink levels over LEDM. Called on open and every 60 s.
    func refreshInk(force: Bool = false) async {
        guard !inkInFlight, !maint.isBusy else { return }
        guard force || Date().timeIntervalSince(lastInkFetch) > 10 else { return }
        if usbPresent == false { ink = nil; inkError = "Printer not connected over USB"; return }
        if case .unavailable(let why) = ledmSupport { ink = nil; inkError = why; return }
        guard let client = currentClient else { return }
        inkInFlight = true
        inkLoading = true
        defer { inkInFlight = false; inkLoading = false }
        lastInkFetch = Date()
        let queue = selected
        do {
            let r = try await client.getAsync("/DevMgmt/ConsumableConfigDyn.xml")
            guard queue == selected else { return }
            ledmSupport = .available
            guard r.status == 200, let report = InkParser.parse(r.body) else {
                inkError = "The printer did not send its ink levels."
                return
            }
            ink = report
            inkError = nil
            notifyInk(report)
        } catch LEDMError.noLEDM {
            guard queue == selected else { return }
            markNoLEDM()
            return
        } catch {
            guard queue == selected else { return }
            inkError = error.localizedDescription
        }
        await maint.loadCapabilities()
    }

    private var currentClient: LEDMClient? {
        guard deviceOpen else { return nil }
        return LEDMClients.shared.client(for: currentSerial)
    }

    private func markNoLEDM() {
        ledmSupport = .unavailable(LEDMSupport.noInkReason)
        ink = nil
        inkError = LEDMSupport.noInkReason
        ledmCategories = nil
    }

    /// One notification per cartridge each time its state changes to a problem state.
    private func notifyInk(_ report: InkReport) {
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled") else { return }
        let d = UserDefaults.standard
        for c in report.cartridges {
            let key = "inkState.\(selected).\(c.label)"
            let prev = d.string(forKey: key)
            guard prev != c.state.rawValue else { continue }
            d.set(c.state.rawValue, forKey: key)
            guard c.state.needsAttention else { continue }
            let pct = c.percent.map { ", \($0)% left" } ?? ""
            notifier.post(title: "\(displayName): \(c.name.lowercased()) ink \(c.state.text.lowercased())",
                          body: "The \(c.name.lowercased()) cartridge in \(displayName) is \(c.state.text.lowercased())\(pct).")
        }
    }

    func refresh() async {
        let name = selected
        let reloadList = printers.isEmpty || pollCount % 10 == 0
        pollCount += 1
        let known = printers
        let snap = await Task.detached(priority: .utility) { () -> Snapshot in
            Snapshot.load(selected: name, reloadList: reloadList, known: known)
        }.value
        if let list = snap.printers { printers = list }
        connection = snap.connection
        if let chosen = snap.resolvedName, chosen != selected {
            selected = chosen
            return
        }
        guard name == selected else { return }
        status = snap.status
        usbPresent = snap.usb
        jobs = snap.jobs
        updateDevice()
        scanner = ScannerState.resolve(hasInterface: snap.scanInterface, sharing: ScannerState.sharingEnabled,
                                       activity: snap.scanActivity)
        updateStale()
        checkNotifications(snap.jobs)
        await refreshLEDM()
    }

    /// Tracks how long CUPS has reported "processing" with no active job.
    private func updateStale() {
        queueStuck = stuckRule.update(stateCode: status?.stateCode, hasActiveJob: activeJob != nil,
                                      printerBusy: isBusy, now: Date())
    }

    /// Reads the printer's own status over LEDM, at most every 5 s and never during maintenance.
    private func refreshLEDM() async {
        guard usbPresent == true, !ledmInFlight, !maint.isBusy, !inkInFlight else {
            if usbPresent != true { ledmCategories = nil }
            return
        }
        if case .unavailable = ledmSupport { ledmCategories = nil; return }
        guard let client = currentClient else { return }
        guard Date().timeIntervalSince(lastLedmFetch) >= 5 else { return }
        ledmInFlight = true
        lastLedmFetch = Date()
        defer { ledmInFlight = false }
        let queue = selected
        do {
            let r = try await client.getAsync("/DevMgmt/ProductStatusDyn.xml")
            guard queue == selected else { return }
            if r.status == 200 {
                ledmSupport = .available
                let cats = Maintenance.statusCategories(r.body)
                ledmCategories = cats.isEmpty ? nil : cats
            } else {
                ledmCategories = nil
            }
        } catch LEDMError.noLEDM {
            guard queue == selected else { return }
            markNoLEDM()
        } catch {
            guard queue == selected else { return }
            ledmCategories = nil
        }
        updateStale()
    }

    private func checkNotifications(_ jobs: [PrintJob]) {
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled") else {
            previousJobStates = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.stateCode) })
            return
        }
        defer { previousJobStates = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.stateCode) }) }
        guard !previousJobStates.isEmpty || !jobs.isEmpty else { return }
        for j in jobs {
            guard let old = previousJobStates[j.id], old >= 3, old <= 6 else { continue }
            if j.stateCode == 9 { notifier.post(title: "Print job completed", body: "\(displayName): \(j.title)") }
            else if j.stateCode == 8 { notifier.post(title: "Print job failed", body: "\(displayName): \(j.title)") }
        }
    }

    // MARK: actions

    func cancel(_ job: PrintJob) { run("Cancel job \(job.id)") { try Cups.cancel(job: job.id, printer: $0) } }
    func cancel(ids: [Int]) { run("Cancel jobs") { p in for id in ids { try Cups.cancel(job: id, printer: p) } } }
    func cancelAll() { run("Cancel all jobs") { try Cups.cancelAll(printer: $0) } }
    func testPage() { run("Test page") { _ = try Cups.printTestPage(printer: $0) } }
    func resetQueue() { run("Reset queue") { try Cups.resetQueue(printer: $0) } }
    func togglePause() {
        let pause = status?.stateCode != 5
        run(pause ? "Pause" : "Resume") { try Cups.setPaused(pause, printer: $0) }
    }

    private func run(_ label: String, _ work: @escaping @Sendable (String) throws -> Void) {
        let name = selected
        Task {
            let result: String? = await Task.detached {
                do { try work(name); return nil } catch {
                    if case CupsError.denied(let m) = error { return m }
                    return "\(label) failed: \(error.localizedDescription)"
                }
            }.value
            actionMessage = result
            await refresh()
        }
    }
}

struct Snapshot: Sendable {
    var printers: [PrinterInfo]?
    var resolvedName: String?
    var status: PrinterStatus?
    var usb: Bool?
    var jobs: [PrintJob] = []
    var connection: [String: Bool] = [:]
    var scanInterface = false
    var scanActivity: PrinterActivity?

    static func filtered(_ all: [PrinterInfo]) -> [PrinterInfo] { PrinterChoice.shown(all) }

    static func load(selected: String, reloadList: Bool, known: [PrinterInfo]) -> Snapshot {
        var snap = Snapshot()
        let list = reloadList ? filtered(Cups.listPrinters()) : known
        if reloadList { snap.printers = list }
        let connected = USBCheck.connectedSerials()
        for p in list {
            if let c = PrinterChoice.connection(of: p, connected: connected) { snap.connection[p.name] = c }
        }
        var info = list.first(where: { $0.name == selected })
        if info == nil, let name = PrinterChoice.resolve(current: selected, in: list) {
            // Selected queue is gone or nothing was chosen yet: take the first match.
            snap.resolvedName = name
            info = list.first { $0.name == name }
        }
        guard let target = info else { return snap }
        if snap.resolvedName != nil { return snap }   // the store re-reads after switching
        let st = Cups.printerStatus(target)
        snap.status = st
        snap.usb = PrinterChoice.connection(of: target, connected: connected)
        snap.jobs = Cups.jobs(for: target.name, limit: 100)
        if snap.usb == true {
            let serial = DeviceURI.serial(st.deviceURI)
            snap.scanInterface = ScannerState.hasScanInterface(serial: serial, in: USBScan.devices())
            if snap.scanInterface, let serial {
                snap.scanActivity = ActivityStore().current(serial: serial, from: .scand)
            }
        }
        return snap
    }
}
