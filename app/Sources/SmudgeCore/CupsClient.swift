// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import CCups

public struct InkSupply: Equatable, Sendable {
    public var name: String
    public var level: Int      // 0...100, negative means unknown
    public var colorHex: String?
}

public struct PrinterInfo: Equatable, Sendable {
    public var name: String
    public var makeAndModel: String
    public var deviceURI: String
}

public struct PrinterStatus: Equatable, Sendable {
    public var name: String
    public var stateCode: Int            // 3 idle, 4 processing, 5 stopped
    public var message: String
    public var reasons: [String]
    public var deviceURI: String
    public var makeAndModel: String
    public var ink: [InkSupply]
    public var error: String?

    public var stateText: String {
        switch stateCode {
        case 3: return "Idle"
        case 4: return "Processing"
        case 5: return "Stopped"
        default: return "Unknown"
        }
    }
}

public struct PrintJob: Identifiable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var user: String
    public var sizeKB: Int
    public var stateCode: Int
    public var time: Date
    public var reasons: [String]

    public var isActive: Bool { stateCode >= 3 && stateCode <= 6 }
    public var stateText: String {
        switch stateCode {
        case 3: return "Pending"
        case 4: return "Held"
        case 5: return "Processing"
        case 6: return "Stopped"
        case 7: return "Canceled"
        case 8: return "Aborted"
        case 9: return "Completed"
        default: return "Unknown"
        }
    }
}

public enum CupsError: Error, LocalizedError {
    case ipp(String)
    case denied(String)     // CUPS answered forbidden or not authorized
    public var errorDescription: String? {
        switch self { case .ipp(let s), .denied(let s): return s }
    }
}

/// Blocking libcups calls. Call from a background context.
public enum Cups {
    static func lastError() -> String {
        if let p = cupsLastErrorString() { return String(cString: p) }
        return "unknown CUPS error"
    }

    public static func listPrinters() -> [PrinterInfo] {
        var dests: UnsafeMutablePointer<cups_dest_t>?
        let n = cupsGetDests2(nil, &dests)
        defer { if let d = dests { cupsFreeDests(n, d) } }
        guard let d = dests, n > 0 else { return [] }
        var out: [PrinterInfo] = []
        for i in 0..<Int(n) {
            let dest = d[i]
            guard dest.is_default >= 0, let np = dest.name else { continue }
            func opt(_ key: String) -> String {
                if let v = cupsGetOption(key, dest.num_options, dest.options) { return String(cString: v) }
                return ""
            }
            out.append(PrinterInfo(name: String(cString: np),
                                   makeAndModel: opt("printer-make-and-model"),
                                   deviceURI: opt("device-uri")))
        }
        return out
    }

    private static func printerURI(_ name: String) -> String {
        "ipp://localhost/printers/" + name
    }

    private static func newRequest(_ op: ipp_op_t, printer: String) -> OpaquePointer {
        let req = ippNewRequest(op)!
        ippAddString(req, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, printerURI(printer))
        ippAddString(req, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", nil, NSUserName())
        return req
    }

    private static func addKeywords(_ req: OpaquePointer, _ name: String, _ values: [String]) {
        var ptrs: [UnsafePointer<CChar>?] = values.map { UnsafePointer(strdup($0)) }
        ippAddStrings(req, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, name, Int32(values.count), nil, &ptrs)
        for p in ptrs { free(UnsafeMutableRawPointer(mutating: p)) }
    }

    private static func strings(_ attr: OpaquePointer?) -> [String] {
        guard let attr else { return [] }
        let c = ippGetCount(attr)
        return (0..<c).compactMap { ippGetString(attr, $0, nil).map { String(cString: $0) } }
    }

    private static func ints(_ attr: OpaquePointer?) -> [Int] {
        guard let attr else { return [] }
        let c = ippGetCount(attr)
        return (0..<c).map { Int(ippGetInteger(attr, $0)) }
    }

    public static func printerStatus(_ info: PrinterInfo) -> PrinterStatus {
        var st = PrinterStatus(name: info.name, stateCode: 0, message: "", reasons: [],
                               deviceURI: info.deviceURI, makeAndModel: info.makeAndModel,
                               ink: [], error: nil)
        let req = newRequest(IPP_OP_GET_PRINTER_ATTRIBUTES, printer: info.name)
        addKeywords(req, "requested-attributes", [
            "printer-state", "printer-state-message", "printer-state-reasons",
            "marker-names", "marker-levels", "marker-colors", "marker-types",
            "device-uri", "printer-make-and-model",
        ])
        guard let resp = cupsDoRequest(nil, req, "/") else {
            st.error = lastError()
            return st
        }
        defer { ippDelete(resp) }
        if ippGetStatusCode(resp).rawValue >= IPP_STATUS_ERROR_BAD_REQUEST.rawValue {
            st.error = lastError()
            return st
        }
        if let a = ippFindAttribute(resp, "printer-state", IPP_TAG_ENUM) { st.stateCode = Int(ippGetInteger(a, 0)) }
        st.message = strings(ippFindAttribute(resp, "printer-state-message", IPP_TAG_TEXT)).first ?? ""
        st.reasons = strings(ippFindAttribute(resp, "printer-state-reasons", IPP_TAG_KEYWORD))
        if let u = strings(ippFindAttribute(resp, "device-uri", IPP_TAG_URI)).first { st.deviceURI = u }
        if let m = strings(ippFindAttribute(resp, "printer-make-and-model", IPP_TAG_TEXT)).first { st.makeAndModel = m }

        let names = strings(ippFindAttribute(resp, "marker-names", IPP_TAG_NAME))
        let levels = ints(ippFindAttribute(resp, "marker-levels", IPP_TAG_INTEGER))
        let colors = strings(ippFindAttribute(resp, "marker-colors", IPP_TAG_NAME))
        for (i, n) in names.enumerated() {
            st.ink.append(InkSupply(name: n,
                                    level: i < levels.count ? levels[i] : -1,
                                    colorHex: i < colors.count ? colors[i] : nil))
        }
        return st
    }

    public static func jobs(for printer: String, limit: Int = 15) -> [PrintJob] {
        var list: UnsafeMutablePointer<cups_job_t>?
        let n = cupsGetJobs2(nil, &list, printer, 0, CUPS_WHICHJOBS_ALL)
        defer { if let l = list { cupsFreeJobs(n, l) } }
        guard let l = list, n > 0 else { return [] }
        var out: [PrintJob] = []
        for i in 0..<Int(n) {
            let j = l[i]
            let state = Int(j.state.rawValue)
            let t = (state >= 7 && j.completed_time != 0) ? j.completed_time
                  : (j.processing_time != 0 ? j.processing_time : j.creation_time)
            out.append(PrintJob(id: Int(j.id),
                                title: j.title.map { String(cString: $0) } ?? "(untitled)",
                                user: j.user.map { String(cString: $0) } ?? "",
                                sizeKB: Int(j.size), stateCode: state,
                                time: Date(timeIntervalSince1970: TimeInterval(t)),
                                reasons: []))
        }
        out.sort { $0.id > $1.id }
        out = Array(out.prefix(limit))
        let reasons = jobReasons(printer)
        for i in out.indices { out[i].reasons = reasons[out[i].id] ?? [] }
        return out
    }

    private static func jobReasons(_ printer: String) -> [Int: [String]] {
        let req = newRequest(IPP_OP_GET_JOBS, printer: printer)
        addKeywords(req, "requested-attributes", ["job-id", "job-state-reasons"])
        ippAddString(req, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "which-jobs", nil, "all")
        ippAddInteger(req, IPP_TAG_OPERATION, IPP_TAG_INTEGER, "limit", 30)
        guard let resp = cupsDoRequest(nil, req, "/") else { return [:] }
        defer { ippDelete(resp) }
        var map: [Int: [String]] = [:]
        var attr = ippFirstAttribute(resp)
        var id: Int?
        while let a = attr {
            if let name = ippGetName(a).map({ String(cString: $0) }) {
                if name == "job-id" { id = Int(ippGetInteger(a, 0)) }
                else if name == "job-state-reasons", let jid = id {
                    map[jid] = strings(a).filter { $0 != "none" }
                }
            }
            attr = ippNextAttribute(resp)
        }
        return map
    }

    /// True for the IPP statuses CUPS returns when the policy refuses the caller.
    private static func isDenied(_ status: ipp_status_t) -> Bool {
        status == IPP_STATUS_ERROR_FORBIDDEN || status == IPP_STATUS_ERROR_NOT_AUTHORIZED
            || status == IPP_STATUS_ERROR_NOT_AUTHENTICATED
    }

    /// Message for a failed request. Refusals get a plain explanation instead of the raw CUPS text.
    private static func failure(_ what: String, status: ipp_status_t, operatorOnly: Bool) -> CupsError {
        if isDenied(status) {
            let need = operatorOnly
                ? "This needs printer operator rights. Use an administrator account, or run the matching command with sudo."
                : "CUPS only lets the job owner or an administrator do this."
            return .denied("\(what): CUPS refused the request (not authorized). \(need)")
        }
        return .ipp("\(what): \(lastError())")
    }

    /// Cancel-Job as the current user. The default CUPS policy lets the job owner do this
    /// without operator rights, as long as requesting-user-name matches the owner and no
    /// operator-only attribute such as purge-job is sent.
    private static func sendCancel(job: Int, printer: String, useJobURI: Bool) -> ipp_status_t {
        let req = ippNewRequest(IPP_OP_CANCEL_JOB)!
        if useJobURI {
            ippAddString(req, IPP_TAG_OPERATION, IPP_TAG_URI, "job-uri", nil, "ipp://localhost/jobs/\(job)")
        } else {
            ippAddString(req, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, printerURI(printer))
            ippAddInteger(req, IPP_TAG_OPERATION, IPP_TAG_INTEGER, "job-id", Int32(job))
        }
        ippAddString(req, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", nil, String(cString: cupsUser()))
        if let resp = cupsDoRequest(nil, req, "/jobs/") { ippDelete(resp) }
        return cupsLastError()
    }

    public static func cancel(job: Int, printer: String) throws {
        var status = sendCancel(job: job, printer: printer, useJobURI: false)
        if isDenied(status) { status = sendCancel(job: job, printer: printer, useJobURI: true) }
        if status.rawValue >= IPP_STATUS_ERROR_BAD_REQUEST.rawValue {
            throw failure("Cancel job \(job)", status: status, operatorOnly: false)
        }
    }

    /// Cancels each active job on its own. The all-jobs operation (Cancel-Jobs) is operator-only.
    public static func cancelAll(printer: String) throws {
        var firstError: Error?
        for j in jobs(for: printer, limit: 100) where j.isActive {
            do { try cancel(job: j.id, printer: printer) } catch { firstError = firstError ?? error }
        }
        if let e = firstError { throw e }
    }

    static func setPaused(_ pause: Bool, printer: String) throws {
        let req = newRequest(pause ? IPP_OP_PAUSE_PRINTER : IPP_OP_RESUME_PRINTER, printer: printer)
        if let resp = cupsDoRequest(nil, req, "/admin/") { ippDelete(resp) }
        let st = cupsLastError()
        if st.rawValue >= IPP_STATUS_ERROR_BAD_REQUEST.rawValue {
            throw failure(pause ? "Pause" : "Resume", status: st, operatorOnly: true)
        }
    }

    /// Pause then resume, the same as cupsdisable followed by cupsenable. Clears a queue that
    /// still reports "processing" after its job is gone.
    public static func resetQueue(printer: String) throws {
        var pauseError: Error?
        do { try setPaused(true, printer: printer) } catch { pauseError = error }
        try setPaused(false, printer: printer)
        if let e = pauseError { throw e }
    }

    static func printTestPage(printer: String) throws -> Int {
        let text = """
        Smudge test page

        Printer: \(printer)
        Date: \(Date().formatted(date: .abbreviated, time: .standard))

        ABCDEFGHIJKLMNOPQRSTUVWXYZ
        abcdefghijklmnopqrstuvwxyz
        0123456789
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("smudge-test-\(getpid()).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let id = cupsPrintFile2(nil, printer, url.path, "Smudge test page", 0, nil)
        if id == 0 { throw CupsError.ipp(lastError()) }
        return Int(id)
    }
}
