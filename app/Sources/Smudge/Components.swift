// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import SwiftUI
import SmudgeCore

/// Shared spacing, radius and type scale. Every screen uses these so edges line up.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    /// Outer padding of every screen, sheet and popover.
    static let page: CGFloat = 20
}

enum Radius {
    static let card: CGFloat = 12
    static let banner: CGFloat = 10
}

enum TypeScale {
    static let screenTitle = Font.title2.bold()
    static let cardTitle = Font.headline
    static let body = Font.body
    static let secondary = Font.callout
    static let note = Font.caption
    /// Instructions people follow with their hands: larger than body text.
    static let lead = Font.system(size: 16)
    static let heroTitle = Font.system(size: 24, weight: .bold)
    static let bigNumber = Font.system(size: 34, weight: .semibold, design: .rounded)
}

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let title { Text(title).font(TypeScale.cardTitle) }
            content
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// A row of cards that all take the height of the tallest one.
struct CardRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .top, spacing: Space.l) { content }
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A tinted box for a notice or warning.
struct Banner<Content: View>: View {
    var tint: Color = .orange
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.banner).fill(tint.opacity(0.14)))
    }
}

extension View {
    /// The main action on a screen: big and filled.
    func primaryAction() -> some View {
        self.buttonStyle(.borderedProminent).controlSize(.large)
    }
    /// A second action next to a primary one: same height, not filled.
    func secondaryAction() -> some View {
        self.buttonStyle(.bordered).controlSize(.large)
    }
}

/// Raw values for people who want them, hidden by default.
struct Details<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        DisclosureGroup("Details") {
            VStack(alignment: .leading, spacing: Space.xs) { content }
                .font(TypeScale.note.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Space.xs)
        }
        .font(TypeScale.note)
    }
}

extension StatusStore.Health {
    var symbol: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .scanning: return "scanner.fill"
        case .printing: return "printer.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .disconnected: return "bolt.slash.fill"
        }
    }
    var color: Color {
        switch self {
        case .ready: return .green
        case .scanning, .printing: return .blue
        case .attention: return .orange
        case .disconnected: return .red
        }
    }
}

extension InkCartridge {
    var stateColor: Color {
        switch state {
        case .ok: return .green
        case .low, .veryLow, .empty, .missing: return .orange
        case .nonHP, .unknown: return .secondary
        }
    }
    var percentText: String { percent.map { "\($0)%" } ?? "unknown" }
    var spoken: String {
        "\(name) cartridge, \(percent.map { "\($0) percent" } ?? "level unknown"), \(state.text)"
    }
}

