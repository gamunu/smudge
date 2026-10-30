// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import SmudgeKit
import SwiftUI

/// Where a guided maintenance flow is.
enum FlowStage: Equatable {
    case prepare
    case starting
    case running            // printer is busy (printing, cleaning, calibrating)
    case awaitScan          // alignment page is out, waiting for the user
    case scanning           // printer is scanning the alignment page
    case cancelling         // asking the printer to cancel its job
    case cancelled(String)  // result of the cancel request
    case done
    case failed(String)
}

/// Something the user has to fix while a flow waits. The job continues by itself afterwards.
enum Attention: Equatable {
    case loadPaper
    case closeDoor
    case other(String)

    var title: String {
        switch self {
        case .loadPaper: return "Put paper in the printer"
        case .closeDoor: return "Close the front door"
        case .other(let s): return s
        }
    }
    var detail: String {
        switch self {
        case .loadPaper: return "Put plain paper in the tray at the back. The job carries on by itself."
        case .closeDoor: return "Close the front door of the printer. The job carries on by itself."
        case .other: return "Check the printer. The job carries on once the problem is fixed."
        }
    }
    var symbol: String {
        switch self {
        case .loadPaper: return "doc.badge.plus"
        case .closeDoor: return "door.left.hand.open"
        case .other: return "exclamationmark.triangle"
        }
    }
}

/// One entry of /Jobs/JobList.
struct LEDMJob: Equatable, Sendable {
    var url: String
    var category: String
    var state: String
    var calibrationState: String?

    /// Anything that is not finished: Processing, Pending, Paused and so on.
    var isActive: Bool {
        let l = state.lowercased()
        return !l.isEmpty && l != "completed" && l != "canceled" && l != "cancelled"
    }
}

/// What a cancel request did.
struct CancelResult: Sendable {
    var found = 0                              // active jobs in the list
    var puts: [(url: String, status: Int)] = []
    var finalCategories: [String]?
    var error: String?

    var stillRunning: Bool {
        guard let c = finalCategories else { return false }
        return c.contains { ["processing", "calibrating"].contains($0.lowercased()) }
    }

    var lines: [String] {
        var out: [String] = []
        if let e = error { return ["The printer did not answer, so nothing was cancelled.", "Details: \(e)"] }
        let final = finalCategories.map { Maintenance.liveText($0) } ?? "unknown"
        if found == 0 {
            out.append("The printer has no active job to cancel.")
            if stillRunning {
                out.append("It still reports \(final.lowercased()). Press the Cancel (X) button on the printer.")
            } else {
                out.append("Printer status: \(final).")
            }
            return out
        }
        out.append("Cancelled \(puts.count) of \(found) active job\(found == 1 ? "" : "s").")
        for p in puts { out.append("PUT \(p.url): HTTP \(p.status)") }
        if stillRunning {
            out.append("The printer still reports \(final.lowercased()). Press the Cancel (X) button on the printer.")
        } else {
            out.append("Printer status: \(final).")
        }
        return out
    }
    var summary: String { lines.joined(separator: "\n") }
}

enum Maintenance {
    static let cancelJobXML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<j:Job xmlns:j=\"http://www.hp.com/schemas/imaging/con/ledm/jobs/2009/04/30\" xmlns:dd=\"http://www.hp.com/schemas/imaging/con/dictionaries/1.0/\" xmlns:fax=\"http://www.hp.com/schemas/imaging/con/fax/2008/06/13\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:schemaLocation=\"http://www.hp.com/schemas/imaging/con/ledm/jobs/2009/04/30 ../schemas/Jobs.xsd\"><j:JobState>Canceled</j:JobState></j:Job>"

    /// Jobs from /Jobs/JobList.
    static func parseJobList(_ data: Data) -> [LEDMJob] {
        guard let root = parseXML(data) else { return [] }
        return root.descendants("Job").compactMap { n in
            guard let url = n.value("JobUrl") else { return nil }
            return LEDMJob(url: url,
                           category: n.value("JobCategory") ?? "",
                           state: n.value("JobState") ?? "",
                           calibrationState: n.descendants("CalibrationState").first?.text
                               .trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Cancels every active job on the printer, then waits up to 20 s for it to stop.
    /// Blocking: call off the main thread.
    static func cancelActivePrinterJobs(client: LEDMClient) -> CancelResult {
        var result = CancelResult()
        do {
            let list = try client.get("/Jobs/JobList", expectRoot: "JobList")
            guard list.status == 200 else {
                result.error = "HTTP \(list.status) \(list.reason) reading the job list"
                return result
            }
            let active = parseJobList(list.body).filter(\.isActive)
            result.found = active.count
            for j in active {
                let r = try client.put(j.url, xml: cancelJobXML)
                result.puts.append((j.url, r.status))
            }
            let deadline = Date().addingTimeInterval(active.isEmpty ? 0 : 20)
            while true {
                if let s = try? client.get("/DevMgmt/ProductStatusDyn.xml"), s.status == 200 {
                    let cats = statusCategories(s.body)
                    result.finalCategories = cats.isEmpty ? nil : cats
                    if !result.stillRunning { break }
                }
                if Date() >= deadline { break }
                Thread.sleep(forTimeInterval: 2)
            }
        } catch {
            result.error = error.localizedDescription
        }
        return result
    }

    // Body from HPLIP base/maint.py (CleanXML, setCleanType), sent as in cleanTypeLedm.
    static func jobXML(_ jobType: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!--  THIS DATA SUBJECT TO DISCLAIMER(S)INCLUDED WITH THE PRODUCT OF ORIGIN. -->\n<ipcap:InternalPrintCap xmlns:ipcap=\"http://www.hp.com/schemas/imaging/con/ledm/internalprintcap/2008/03/21\" xmlns:ipdyn=\"http://www.hp.com/schemas/imaging/con/ledm/internalprintdyn/2008/03/21\" xmlns:dd=\"http://www.hp.com/schemas/imaging/con/dictionaries/1.0/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:schemaLocation=\"http://www.hp.com/schemas/imaging/con/ledm/internalprintcap/2008/03/21 ../schemas/InternalPrintCap.xsd http://www.hp.com/schemas/imaging/con/ledm/internalprintdyn/2008/03/21 ../schemas/InternalPrintDyn.xsd http://www.hp.com/schemas/imaging/con/dictionaries/1.0/ ../schemas/dd/DataDictionaryMasterLEDM.xsd\">\n                                <ipdyn:JobType>\(jobType)</ipdyn:JobType>\n</ipcap:InternalPrintCap>"
    }

    // base/maint.py dataModelHelper, with the attribute quotes written as plain quotes.
    static let calibrationPrintingXML = "<cal:CalibrationState xmlns:cal=\"http://www.hp.com/schemas/imaging/con/cnx/markingagentcalibration/2009/04/08\" xmlns:dd=\"http://www.hp.com/schemas/imaging/con/dictionaries/1.0/\">Printing</cal:CalibrationState>"

    /// Words for the calibration state XML. ScanRequested is checked before Scanning.
    static func calibrationWord(_ xml: String) -> String? {
        for w in ["CalibrationValid", "CalibrationRequired", "ParmsRequested", "ScanRequested", "Scanning", "Printing"]
        where xml.contains(w) { return w }
        return nil
    }

    static func supportedJobTypes(_ data: Data) -> [String] {
        guard let root = parseXML(data) else { return [] }
        return root.descendants("JobType").map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Status categories from ProductStatusDyn.
    static func statusCategories(_ data: Data) -> [String] {
        guard let root = parseXML(data) else { return [] }
        return root.all("Status").compactMap { $0.value("StatusCategory") }
    }

    static func isBusy(_ categories: [String]) -> Bool {
        categories.contains { c in
            let l = c.lowercased()
            return ["process", "clean", "align", "calibrat", "busy", "printing", "initializ", "warm"].contains { l.contains($0) }
        }
    }

    /// The first category that needs the user. genuineHP and ready are informational.
    static func attention(_ categories: [String]) -> Attention? {
        for c in categories {
            let l = c.lowercased()
            if l == "trayemptyoropen" { return .loadPaper }
            if l == "closedoororcover" { return .closeDoor }
            if ["jam", "error", "inkout", "inkempty", "cartridge", "missing"].contains(where: { l.contains($0) }) {
                return .other(describe(c))
            }
        }
        return nil
    }

    /// Plain words for a status category.
    static func describe(_ category: String) -> String {
        switch category.lowercased() {
        case "ready": return "Ready"
        case "processing": return "Printing"
        case "calibrating": return "Aligning"
        case "trayemptyoropen": return "Paper tray empty or open"
        case "closedoororcover": return "Door or cover open"
        case "genuinehp": return "Genuine HP cartridges"
        default: return category
        }
    }

    /// Summary of the live categories for display, ignoring informational ones.
    static func liveText(_ categories: [String]) -> String {
        let shown = categories.filter { $0.lowercased() != "genuinehp" }
        if shown.isEmpty { return categories.isEmpty ? "Waiting for the printer" : "Ready" }
        return shown.map(describe).joined(separator: ", ")
    }
}

@MainActor
final class MaintenanceController: ObservableObject {
    @Published var job: MaintenanceJob? { didSet { syncActivity() } }   // non-nil while the guided sheet is open
    @Published var stage: FlowStage = .prepare { didSet { syncActivity() } }
    @Published var categories: [String] = []     // live ProductStatusDyn categories
    @Published var calState: String?             // live /Calibration/State, alignment only
    @Published var attention: Attention?
    @Published var reached = 0                   // index of the furthest step shown
    @Published var note: String?                 // extra line on the done screen
    @Published var caps: PrinterCaps?            // read once per printer, nil until then
    @Published var cancelling = false { didSet { syncActivity() } }   // a cancel request is in progress
    @Published var cancelOutcome: String?        // result of the last cancel, shown for a while

    private var task: Task<Void, Never>?
    private var client: LEDMClient?
    private var capsInFlight = false
    private let pollInterval: Duration = .seconds(2)

    private let activity = ActivityStore()
    private var activityOn = false
    private var activitySerial: String?

    /// Tells the scanner agent while maintenance runs, so it refuses scans until the printer is free.
    private func syncActivity() {
        let on = isBusy
        guard on != activityOn, let serial = activitySerial ?? client?.serial else { return }
        activityOn = on
        activitySerial = on ? serial : nil
        activity.set(on ? .maintenance : nil, serial: serial, writer: .app)
    }

    var isBusy: Bool {
        if cancelling { return true }
        guard job != nil else { return false }
        switch stage {
        case .starting, .running, .awaitScan, .scanning: return true
        default: return false
        }
    }

    static func steps(for job: MaintenanceJob, alignment: AlignmentSupport? = nil) -> [String] {
        switch job {
        case .clean, .deepClean: return ["Prepare", "Cleaning", "Done"]
        case .diagnostics: return ["Prepare", "Printing", "Check"]
        case .align:
            return alignment == .automatic ? ["Prepare", "Aligning", "Done"] : ["Prepare", "Printing", "Scan", "Done"]
        }
    }

    /// Shows a fixed step with fake state. No printer calls. Only used by `--preview-step`.
    func applyPreview(_ spec: PreviewMode.Spec) {
        job = spec.job
        stage = spec.stage
        reached = spec.reached
        attention = spec.attention
        categories = spec.categories
        calState = spec.calState
    }

    /// Points the controller at the selected printer's LEDM client. Forgets what it knew about the
    /// previous printer.
    func configure(client: LEDMClient?) {
        guard client !== self.client else { return }
        task?.cancel()
        task = nil
        job = nil
        reset()
        syncActivity()       // clears the entry for the old printer
        self.client = client
        caps = nil
    }

    func supports(_ job: MaintenanceJob) -> Bool { caps?.cards.contains(job) ?? false }

    private func ledm() throws -> LEDMClient {
        guard let client else { throw LEDMError.noLEDM }
        return client
    }

    /// Reads what the printer can do. Runs on first contact and again until it succeeds.
    func loadCapabilities() async {
        guard caps == nil, !capsInFlight, let c = client else { return }
        capsInFlight = true
        defer { capsInFlight = false }
        guard let r = try? await c.getAsync("/DevMgmt/InternalPrintCap.xml"), r.status == 200 else { return }
        let cfg = try? await c.getAsync("/DevMgmt/ConsumableConfigDyn.xml")
        let parsed = PrinterCaps.parse(printCap: r.body, consumables: cfg?.status == 200 ? cfg?.body : nil)
        guard c === client else { return }   // the selection changed while reading
        caps = parsed
    }

    // MARK: sheet control

    func open(_ job: MaintenanceJob) {
        guard !isBusy else { return }
        task?.cancel()
        reset()
        self.job = job
    }

    /// Stops the running flow, then asks the printer to cancel whatever job it has.
    func cancelFlow() async {
        guard job != nil, !cancelling else { return }
        task?.cancel()
        await task?.value          // let an in-flight request finish so it cannot overwrite the stage
        task = nil
        stage = .cancelling
        let r = await performCancel()
        attention = nil
        stage = .cancelled(r.summary)
    }

    /// Cancel from outside the sheet (Overview, menu bar).
    func cancelPrinterJob() async {
        guard !cancelling else { return }
        let r = await performCancel()
        cancelOutcome = r.summary
        let shown = r.summary
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            if self?.cancelOutcome == shown { self?.cancelOutcome = nil }
        }
    }

    private func performCancel() async -> CancelResult {
        cancelling = true
        defer { cancelling = false }
        guard let c = client else { return CancelResult(error: LEDMError.noLEDM.localizedDescription) }
        return await Task.detached { Maintenance.cancelActivePrinterJobs(client: c) }.value
    }

    /// Closes the sheet. The printer keeps going with a job it already started.
    func close() {
        task?.cancel()
        task = nil
        job = nil
        reset()
    }

    func retry() {
        guard let j = job else { return }
        task?.cancel()
        reset()
        job = j
    }

    private func reset() {
        stage = .prepare
        categories = []
        calState = nil
        attention = nil
        reached = 0
        note = nil
        cancelOutcome = nil
    }

    func begin() {
        guard let job, !isBusy else { return }
        stage = .starting
        reached = 1
        task = Task { [weak self] in
            guard let self else { return }
            if job == .align { await self.runAlign() } else { await self.runJob(job) }
        }
    }

    private func fail(_ message: String) { stage = .failed(message) }

    private func readCategories() async -> [String]? {
        guard let s = try? await ledm().getAsync("/DevMgmt/ProductStatusDyn.xml"), s.status == 200 else { return nil }
        let cats = Maintenance.statusCategories(s.body)
        return cats.isEmpty ? nil : cats
    }

    // MARK: clean, deep clean, diagnostics

    /// Clean and diagnostics: send the job, then watch the status categories every 2 s.
    /// Done when the printer was busy and is ready again with nothing for the user to fix.
    private func runJob(_ job: MaintenanceJob) async {
        guard let jt = job.jobType else { return }
        do {
            let r = try await ledm().postAsync("/DevMgmt/InternalPrintDyn.xml", xml: Maintenance.jobXML(jt))
            guard (200..<300).contains(r.status) else {
                fail("The printer did not accept the request. Try again.\nDetails: HTTP \(r.status) \(r.reason)")
                return
            }
            stage = .running
            try await watchUntilQuiet(doneReached: 2)
        } catch is CancellationError {
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Watches the status categories every 2 s. Done when the printer was busy and is ready again
    /// with nothing for the user to fix.
    private func watchUntilQuiet(doneReached: Int) async throws {
        var sawBusy = false, quiet = 0, failures = 0
        let started = Date()
        while true {
            try await Task.sleep(for: pollInterval)
            if Date().timeIntervalSince(started) > 300 {
                fail("The printer did not finish within 5 minutes. Check it, then try again.")
                return
            }
            guard let cats = await readCategories() else {
                failures += 1
                if failures >= 10 { fail("The printer stopped answering."); return }
                continue
            }
            failures = 0
            categories = cats
            let a = Maintenance.attention(cats)
            attention = a
            if Maintenance.isBusy(cats) { sawBusy = true; quiet = 0 }
            else if a == nil { quiet += 1 }
            else { quiet = 0 }
            if (sawBusy && quiet >= 2) || (!sawBusy && quiet >= 10) {
                if !sawBusy { note = "The printer did not report any activity, so the job may have finished very quickly." }
                stage = .done
                reached = doneReached
                return
            }
        }
    }

    // MARK: alignment (base/maint.py dataModelHelper, AlignType15)

    private func readCalibration() async -> String? {
        guard let s = try? await ledm().getAsync("/Calibration/State", expectRoot: "CalibrationState"),
              s.status == 200 else { return nil }
        return Maintenance.calibrationWord(s.text)
    }

    /// Sequence seen on a semi-automatic printer (DeskJet 2300) over USB:
    /// CalibrationRequired -> Printing (calibrating) -> ScanRequested -> Scanning -> CalibrationRequired + ready.
    /// The printer does not report CalibrationValid after a good alignment, so success is
    /// "passed through Scanning, then ready with nothing to fix". CalibrationValid also counts.
    private func runAlign() async {
        do {
            var state = try await ledm().getAsync("/Calibration/State", expectRoot: "CalibrationState")
            if state.body.isEmpty { state = try await ledm().getAsync("/Calibration/State", expectRoot: "CalibrationState") }
            if state.status == 404 {
                fail("This printer does not support alignment over this channel.")
                return
            }
            let st = state.text
            if st.contains("ParmsRequested") {
                fail("The printer is waiting for an earlier alignment. Turn it off and on, then try again.")
                return
            }
            if st.contains("Printing<") {
                fail("A previous alignment job has not finished. Wait for the printer to go idle.")
                return
            }
            let cfg = try await ledm().getAsync("/DevMgmt/ConsumableConfigDyn.xml")
            let mode = InkParser.parse(cfg.body)?.alignmentMode ?? ""
            guard cfg.text.contains("AlignmentMode") else {
                fail("This printer does not report an alignment mode.")
                return
            }
            if mode == "manual" {
                fail("This printer uses manual alignment, which this app does not support.")
                return
            }
            let r = try await ledm().postFooterAsync("/Calibration/Session", xml: Maintenance.calibrationPrintingXML)
            guard (200..<300).contains(r.status) else {
                fail("The printer did not accept the request. Try again.\nDetails: HTTP \(r.status) \(r.reason)")
                return
            }
            if mode == "automatic" {
                note = "The printer aligns itself. You do not need to scan anything."
                stage = .running
                try await watchUntilQuiet(doneReached: 2)
                return
            }
            stage = .running

            var tracker = AlignTracker(started: Date())
            while true {
                try await Task.sleep(for: pollInterval)
                if case .failed(let m) = tracker.checkTimeout(now: Date()) { fail(m); return }
                let cats = await readCategories()
                let cal = await readCalibration()
                let step = tracker.observe(cats: cats, cal: cal)
                categories = tracker.categories
                calState = tracker.calState
                attention = tracker.attention
                switch step {
                case .keepGoing:
                    stage = tracker.stage
                    reached = tracker.reached
                case .done:
                    stage = .done
                    reached = 3
                    return
                case .failed(let m):
                    fail(m)
                    return
                }
            }
        } catch is CancellationError {
        } catch {
            fail(error.localizedDescription)
        }
    }
}
