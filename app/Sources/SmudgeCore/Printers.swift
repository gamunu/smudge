// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import SmudgeKit

// MARK: device URI

public enum DeviceURI {
    public static func isUSB(_ uri: String) -> Bool { uri.lowercased().hasPrefix("usb:") }

    /// The serial in usb://HP/<model>?serial=XXXX, nil when absent or empty.
    public static func serial(_ uri: String) -> String? {
        guard isUSB(uri), let c = URLComponents(string: uri) else { return nil }
        let v = c.queryItems?.first(where: { $0.name.lowercased() == "serial" })?.value
        guard let v, !v.isEmpty else { return nil }
        return v
    }

    /// "DeskJet 2300 series" from usb://HP/DeskJet%202300%20series?serial=X (percent-decoded).
    public static func model(_ uri: String) -> String? {
        guard isUSB(uri), let c = URLComponents(string: uri) else { return nil }
        let path = c.path.hasPrefix("/") ? String(c.path.dropFirst()) : c.path
        return path.isEmpty ? nil : path
    }
}

// MARK: capabilities

public enum AlignmentSupport: String, Equatable, Sendable {
    case automatic, semiAutomatic, manual, none

    init(mode: String?) {
        switch mode?.lowercased() {
        case "automatic": self = .automatic
        case "semiautomatic": self = .semiAutomatic
        case "manual": self = .manual
        default: self = .none
        }
    }

    public var summary: String {
        switch self {
        case .automatic: return "automatic"
        case .semiAutomatic: return "semi-automatic (scan the page)"
        case .manual: return "manual (not supported by this app)"
        case .none: return "none reported"
        }
    }
}

/// What one printer can do, read once from /DevMgmt/InternalPrintCap.xml and ConsumableConfigDyn.
public struct PrinterCaps: Equatable, Sendable {
    public var jobTypes: [String]
    public var alignment: AlignmentSupport

    /// Maintenance cards that work on this printer. Manual alignment gets no card.
    public var cards: [MaintenanceJob] {
        var out: [MaintenanceJob] = []
        for job in MaintenanceJob.allCases {
            if let jt = job.jobType {
                if jobTypes.contains(jt) { out.append(job) }
            } else if alignment == .automatic || alignment == .semiAutomatic {
                out.append(job)
            }
        }
        return out
    }

    public var alignmentNote: String? {
        alignment == .manual ? "This printer uses manual alignment, which this app does not support." : nil
    }

    public static func parse(printCap: Data, consumables: Data?) -> PrinterCaps {
        let types = Maintenance.supportedJobTypes(printCap)
        let mode = consumables.flatMap { InkParser.parse($0)?.alignmentMode }
        return PrinterCaps(jobTypes: types, alignment: AlignmentSupport(mode: mode))
    }
}

public enum LEDMSupport: Equatable, Sendable {
    case unknown
    case available
    case unavailable(String)

    public static let noInkReason = LEDMError.noInterfaceReason
}

// MARK: queue choice

public enum PrinterChoice {
    static func isOurs(_ p: PrinterInfo) -> Bool {
        p.makeAndModel.trimmingCharacters(in: .whitespaces).lowercased().hasSuffix("smudge")
    }

    static func isHP(_ p: PrinterInfo) -> Bool {
        let m = p.makeAndModel.lowercased()
        return m.hasPrefix("hp ") || m.hasPrefix("hewlett") || p.deviceURI.lowercased().hasPrefix("usb://hp/")
    }

    /// Queues made with this driver, else any HP queue, else every queue.
    public static func shown(_ all: [PrinterInfo]) -> [PrinterInfo] {
        let ours = all.filter(isOurs)
        if !ours.isEmpty { return ours }
        let hp = all.filter(isHP)
        return hp.isEmpty ? all : hp
    }

    /// Keeps the remembered queue when it still exists, else the first one. nil when there are none.
    static func resolve(current: String, in list: [PrinterInfo]) -> String? {
        if list.contains(where: { $0.name == current }) { return current }
        return list.first?.name
    }

    /// True or false for a USB queue with a serial, nil when there is nothing to check.
    public static func connection(of p: PrinterInfo, connected: Set<String>) -> Bool? {
        guard DeviceURI.isUSB(p.deviceURI), let s = DeviceURI.serial(p.deviceURI) else { return nil }
        return connected.contains(s)
    }
}
