// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import SmudgeKit

/// Queue named by --printer, else the first shown queue.
func cliPrinter() -> PrinterInfo? {
    let shown = PrinterChoice.shown(Cups.listPrinters())
    if let i = cliArgs.firstIndex(of: "--printer"), i + 1 < cliArgs.count {
        return shown.first { $0.name == cliArgs[i + 1] }
    }
    return shown.first
}

/// Command-line self-check: prints what the GUI would show for every printer.
func dumpAndExit() -> Never {
    let all = Cups.listPrinters()
    print("Queues (all): \(all.map(\.name).joined(separator: ", "))")
    var shown = PrinterChoice.shown(all)
    print("Queues (shown): \(shown.map(\.name).joined(separator: ", "))")
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--printer"), i + 1 < args.count { shown = shown.filter { $0.name == args[i + 1] } }
    if shown.isEmpty { print("No printer queues found"); exit(1) }

    print("\nUSB devices from HP:")
    let hp = USBScan.devices().filter { $0.vendor == LEDMMatch.hpVendor }
    if hp.isEmpty { print("  (none)") }
    for d in hp {
        let ledm = LEDMMatch.ledmInterface(of: d).map { "LEDM interface \($0.number)" } ?? "no LEDM interface"
        print("  \(String(d.product, radix: 16)) serial=\(d.serial ?? "none") \(ledm)")
    }

    let verbose = args.contains("-v")
    for info in shown {
        let st = Cups.printerStatus(info)
        print("\nPrinter: \(st.name)")
        print("Model: \(st.makeAndModel)")
        print("Device URI: \(st.deviceURI)")
        if let e = st.error { print("Error: \(e)") }
        print("State: \(st.stateText) (\(st.stateCode))")
        print("Message: \(st.message.isEmpty ? "(none)" : st.message)")
        print("Reasons (raw): \(st.reasons.joined(separator: ", "))")
        let plain = StatusText.describe(all: st.reasons)
        print("Reasons (plain): \(plain.isEmpty ? "(none)" : plain.joined(separator: "; "))")
        let serial = DeviceURI.serial(st.deviceURI)
        print("USB serial: \(serial ?? "none")")
        guard DeviceURI.isUSB(st.deviceURI) else {
            print("USB device present: n/a")
            print("LEDM: unavailable (not a USB queue)")
            continue
        }
        let lookup = LEDMMatch.lookup(serial: serial, in: USBScan.devices())
        switch lookup {
        case .notConnected:
            print("USB device present: no")
            print("LEDM: unavailable (printer not connected)")
        case .noLEDM(let dev):
            print("USB device present: yes (product \(String(dev.product, radix: 16)))")
            print("LEDM: unavailable (\(LEDMSupport.noInkReason))")
        case .found(let dev, let iface):
            print("USB device present: yes (product \(String(dev.product, radix: 16)))")
            print("LEDM: available (interface \(iface.number))")
            let client = LEDMClients.shared.client(for: serial)
            client.verbose = verbose
            do {
                let cfg = try client.get("/DevMgmt/ConsumableConfigDyn.xml")
                if let rep = InkParser.parse(cfg.body), !rep.cartridges.isEmpty {
                    for c in rep.cartridges {
                        let pct = c.percent.map { "\($0)%" } ?? "unknown"
                        print("Ink: \(c.name) (\(c.label)) level=\(pct) state=\(c.state.text) raw=\(c.rawState) measured=\(c.measured) product=\(c.product ?? "?")")
                    }
                } else {
                    print("Ink: unknown (HTTP \(cfg.status), no cartridges parsed)")
                }
                let cap = try client.get("/DevMgmt/InternalPrintCap.xml")
                let caps = PrinterCaps.parse(printCap: cap.body, consumables: cfg.status == 200 ? cfg.body : nil)
                print("Maintenance job types: \(caps.jobTypes.isEmpty ? "unknown" : caps.jobTypes.joined(separator: ", "))")
                print("Alignment: \(caps.alignment.summary)")
                print("Maintenance cards: \(caps.cards.isEmpty ? "none" : caps.cards.map(\.title).joined(separator: ", "))")
                if let n = caps.alignmentNote { print("Note: \(n)") }
            } catch {
                print("LEDM error: \(error.localizedDescription)")
            }
        }
        if st.ink.isEmpty {
            print("Ink (CUPS): not available")
        } else {
            for s in st.ink { print("Ink (CUPS): \(s.name) \(s.level)% \(s.colorHex ?? "")") }
        }
        let jobs = Cups.jobs(for: info.name)
        print("Jobs: \(jobs.count)")
        for j in jobs {
            print("  #\(j.id) \(j.stateText) \"\(j.title)\" user=\(j.user) \(j.sizeKB)KB \(j.time.formatted(date: .abbreviated, time: .standard)) reasons=\(j.reasons.joined(separator: ","))")
        }
    }
    exit(0)
}

/// Debug helper: GET one LEDM resource and print the raw body.
/// Starts a clean, deep clean or diagnostics page from the command line.
func maintJobAndExit(name: String) -> Never {
    guard name == "cancel" || MaintenanceJob(rawValue: name) != nil else {
        FileHandle.standardError.write(Data("usage: --maint clean|deepClean|diagnostics|align|cancel\n".utf8))
        exit(64)
    }
    if name == "cancel" {
        let r = Maintenance.cancelActivePrinterJobs(client: cliClient())
        print(r.summary)
        exit(r.error == nil ? 0 : 1)
    }
    let job = MaintenanceJob(rawValue: name)!
    let client = cliClient()
    do {
        let r: LEDMResponse
        if let jt = job.jobType {
            r = try client.post("/DevMgmt/InternalPrintDyn.xml", xml: Maintenance.jobXML(jt))
        } else {
            r = try client.postFooter("/Calibration/Session", xml: Maintenance.calibrationPrintingXML)
        }
        print("\(job.title): HTTP \(r.status) \(r.reason)")
        exit((200..<300).contains(r.status) ? 0 : 2)
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

func ledmGetAndExit(path: String) -> Never {
    do {
        let r = try cliClient().get(path)
        FileHandle.standardError.write(Data("HTTP \(r.status) \(r.reason)\n".utf8))
        FileHandle.standardOutput.write(r.body)
        if r.body.last != 10 { print("") }
        exit(r.status == 200 ? 0 : 2)
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

/// Cancels one job through the same code path the GUI uses.
func cancelJobAndExit(id: Int?) -> Never {
    guard let id else {
        FileHandle.standardError.write(Data("usage: --cancel <job-id> [--printer <name>]\n".utf8))
        exit(64)
    }
    guard let name = cliPrinter()?.name else {
        FileHandle.standardError.write(Data("error: no printer queue found\n".utf8))
        exit(1)
    }
    do {
        try Cups.cancel(job: id, printer: name)
        print("Canceled job \(id) on \(name)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

/// LEDM client for the printer named by --printer (default: first queue), with -v logging.
func cliClient() -> LEDMClient {
    let uri = cliPrinter().map { Cups.printerStatus($0).deviceURI } ?? ""
    let c = LEDMClients.shared.client(for: DeviceURI.serial(uri))
    c.verbose = cliArgs.contains("-v")
    return c
}

/// Prints the parsed /Jobs/JobList (read-only).
func ledmJobsAndExit() -> Never {
    do {
        let r = try cliClient().get("/Jobs/JobList", expectRoot: "JobList")
        guard r.status == 200 else { print("HTTP \(r.status) \(r.reason)"); exit(2) }
        let jobs = Maintenance.parseJobList(r.body)
        print("Printer jobs: \(jobs.count), active: \(jobs.filter(\.isActive).count)")
        for j in jobs {
            let cal = j.calibrationState.map { " calibration=\($0)" } ?? ""
            print("  \(j.url) category=\(j.category) state=\(j.state) active=\(j.isActive ? "yes" : "no")\(cal)")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
