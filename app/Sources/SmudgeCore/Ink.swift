// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import SmudgeKit

/// Tiny namespace-agnostic XML tree, enough for LEDM documents.
final class XMLNode {
    let name: String            // local name, prefix removed
    var text = ""
    var children: [XMLNode] = []
    init(name: String) { self.name = name }

    func first(_ n: String) -> XMLNode? { children.first { $0.name == n } }
    func all(_ n: String) -> [XMLNode] { children.filter { $0.name == n } }
    func value(_ path: String...) -> String? {
        var node: XMLNode? = self
        for p in path { node = node?.first(p) }
        guard let t = node?.text.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
    func descendants(_ n: String) -> [XMLNode] {
        var out: [XMLNode] = []
        for c in children {
            if c.name == n { out.append(c) }
            out += c.descendants(n)
        }
        return out
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLNode?
    private var stack: [XMLNode] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let n = XMLNode(name: local)
        if let top = stack.last { top.children.append(n) } else { root = n }
        stack.append(n)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) { _ = stack.popLast() }
}

func parseXML(_ data: Data) -> XMLNode? {
    let b = XMLTreeBuilder()
    let p = XMLParser(data: data)
    p.delegate = b
    p.shouldProcessNamespaces = false
    return p.parse() ? b.root : (b.root)
}

public enum InkState: String, Equatable, Sendable {
    case ok, low, veryLow, empty, missing, nonHP, unknown

    public var text: String {
        switch self {
        case .ok: return "OK"
        case .low: return "Low"
        case .veryLow: return "Very low"
        case .empty: return "Empty"
        case .missing: return "Missing"
        case .nonHP: return "Non-HP or refilled"
        case .unknown: return "Unknown"
        }
    }

    /// States worth a notification.
    var needsAttention: Bool {
        switch self {
        case .low, .veryLow, .empty, .missing: return true
        default: return false
        }
    }
}

public struct InkCartridge: Identifiable, Equatable, Sendable {
    public var label: String          // CMY or K, as the printer reports it
    public var percent: Int?          // nil when the printer does not report one
    public var state: InkState
    public var rawState: String
    public var measured: String
    public var product: String?       // e.g. 682

    public var id: String { label }
    public var bands: [InkBand] { InkLabel.bands(label) }
    public var name: String { InkLabel.name(label) }
    public var isBlack: Bool { bands == [.black] }
    public var isMulti: Bool { bands.count > 1 }
    public var colorHex: String { bands.first?.hex ?? InkBand.other.hex }
}

/// One color stripe of a cartridge.
public enum InkBand: String, Equatable, Sendable {
    case cyan, magenta, yellow, black, lightCyan, lightMagenta, photo, gray, other

    public var hex: String {
        switch self {
        case .cyan: return "#00ADEE"
        case .magenta: return "#E6198C"
        case .yellow: return "#FFD900"
        case .black: return "#222222"
        case .lightCyan: return "#7FD6F7"
        case .lightMagenta: return "#F28CC5"
        case .photo: return "#3B3B3B"
        case .gray: return "#8A8A8A"
        case .other: return "#888888"
        }
    }
    public var title: String {
        switch self {
        case .cyan: return "Cyan"
        case .magenta: return "Magenta"
        case .yellow: return "Yellow"
        case .black: return "Black"
        case .lightCyan: return "Light cyan"
        case .lightMagenta: return "Light magenta"
        case .photo: return "Photo black"
        case .gray: return "Gray"
        case .other: return "Ink"
        }
    }
}

/// Reads the label codes printers send (K, C, M, Y, CMY, CMYK, LC, LM, PK and so on).
public enum InkLabel {
    public static func bands(_ label: String) -> [InkBand] {
        let l = label.uppercased()
        switch l {
        case "LC": return [.lightCyan]
        case "LM": return [.lightMagenta]
        case "PK", "PB": return [.photo]
        case "GY", "G": return [.gray]
        default: break
        }
        guard !l.isEmpty, l.allSatisfy({ "CMYK".contains($0) }) else { return [.other] }
        return l.map { c in
            switch c {
            case "C": return .cyan
            case "M": return .magenta
            case "Y": return .yellow
            default: return .black
            }
        }
    }

    public static func name(_ label: String) -> String {
        let b = bands(label)
        if b == [.other] { return label }
        if b.count == 1 { return b[0].title }
        let l = label.uppercased()
        if l == "CMY" { return "Tri-color" }
        if l == "CMYK" { return "Four-color" }
        return b.map(\.title).joined(separator: " + ")
    }
}

public struct InkReport: Equatable, Sendable {
    public var cartridges: [InkCartridge]
    var alignmentMode: String?
    public var fetched: Date
}

public enum InkParser {
    /// Maps the ConsumableConfigDyn reply to cartridges. Level and state rules follow
    /// HPLIP's StatusType10Agents (base/status.py): 0 percent means empty (unless the
    /// quantity state is unknown) and 10 percent or less means low.
    public static func parse(_ data: Data) -> InkReport? {
        guard let root = parseXML(data), root.name == "ConsumableConfigDyn" else { return nil }
        var out: [InkCartridge] = []
        for info in root.all("ConsumableInfo") {
            let type = info.value("ConsumableTypeEnum") ?? ""
            guard ["ink", "inkCartridge", "inkTank", "toner", "tonerCartridge", "rechargeableToner"].contains(type)
            else { continue }
            let label = info.value("ConsumableLabelCode") ?? "?"
            let raw = info.value("ConsumableLifeState", "ConsumableState") ?? "unknown"
            let measured = info.value("ConsumableLifeState", "MeasuredQuantityState") ?? "unknown"
            let brand = info.value("ConsumableLifeState", "Brand")
            let refilled = info.value("ConsumableLifeState", "IsRefilled") == "true"
            let pct = info.value("ConsumablePercentageLevelRemaining").flatMap { Int($0) }.map { max(0, min(100, $0)) }
            let state = classify(raw: raw, measured: measured, percent: pct, brand: brand, refilled: refilled)
            out.append(InkCartridge(label: label, percent: pct, state: state, rawState: raw,
                                    measured: measured, product: info.value("ConsumableSelectibilityNumber")))
        }
        let mode = root.descendants("AlignmentMode").first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return InkReport(cartridges: out, alignmentMode: mode, fetched: Date())
    }

    static func classify(raw: String, measured: String, percent: Int?, brand: String?, refilled: Bool) -> InkState {
        let r = raw.lowercased()
        if r.contains("missing") || r.contains("misinstalled") { return .missing }
        if r.contains("nonhp") || r.contains("refill") || r.contains("counterfeit") || refilled
            || (brand != nil && brand!.uppercased() != "HP" && brand!.lowercased() != "unknown") {
            return .nonHP
        }
        if r == "empty" || r == "out" || r.contains("depleted") { return .empty }
        if r.contains("verylow") { return .veryLow }
        if r == "low" { return .low }
        if let p = percent {
            if p == 0 { return measured == "unknown" ? .unknown : .empty }
            if p <= 5 { return .veryLow }
            if p <= 10 { return .low }
        }
        if r == "unknown" { return .unknown }
        return .ok   // ok, genuineHP, newGenuineHP, and similar
    }
}

public enum MaintenanceJob: String, CaseIterable, Identifiable, Sendable {
    case clean, deepClean, diagnostics, align

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .clean: return "Clean print heads"
        case .deepClean: return "Deep clean"
        case .diagnostics: return "Check print quality"
        case .align: return "Line up print heads"
        }
    }
    /// InternalPrintDyn JobType, nil for alignment.
    public var jobType: String? {
        switch self {
        case .clean: return "cleaningPage"
        case .deepClean: return "cleaningPageLevel2"
        case .diagnostics: return "diagnosticsPage"
        case .align: return nil
        }
    }
}
