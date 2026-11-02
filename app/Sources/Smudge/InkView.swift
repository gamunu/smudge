// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import SwiftUI
import SmudgeCore

struct InkView: View {
    @ObservedObject var store: StatusStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cartridges").font(TypeScale.screenTitle)
                        Text(lastRead).font(TypeScale.secondary).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.inkLoading { ProgressView().controlSize(.small) }
                    Button { Task { await store.refreshInk(force: true) } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .secondaryAction()
                    .disabled(store.inkLoading || store.maint.isBusy)
                }
                if let r = store.ink, !r.cartridges.isEmpty {
                    CardRow {
                        ForEach(r.cartridges.sorted { $0.isBlack && !$1.isBlack }) { CartridgeCard(cartridge: $0) }
                    }
                } else {
                    Card {
                        Label(store.inkError ?? "Reading ink levels", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Space.page)
        }
    }

    private var lastRead: String {
        guard let r = store.ink else { return "Not read yet" }
        return "Last read \(r.fetched.formatted(date: .omitted, time: .standard))"
    }
}

struct CartridgeCard: View {
    let cartridge: InkCartridge

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: Space.page) {
                CartridgeShape(cartridge: cartridge)
                    .frame(width: 110, height: 170)
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(cartridge.name).font(.title3.bold())
                    Text(cartridge.percentText)
                        .font(TypeScale.bigNumber)
                        .foregroundStyle(cartridge.percent == nil ? .secondary : .primary)
                    Label(cartridge.state.text, systemImage: symbol)
                        .foregroundStyle(cartridge.stateColor)
                    Text("HP \(cartridge.product ?? "unknown") cartridge")
                        .font(TypeScale.secondary).foregroundStyle(.secondary)
                    if cartridge.percent == nil {
                        Text("The printer does not say how full it is.").font(TypeScale.note).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cartridge.spoken + (cartridge.product.map { ", HP \($0)" } ?? ""))
    }

    private var symbol: String {
        switch cartridge.state {
        case .ok: return "checkmark.circle"
        case .nonHP, .unknown: return "questionmark.circle"
        default: return "exclamationmark.triangle"
        }
    }
}

/// Cartridge outline with the level drawn as filled bands, one per ink color the label names.
struct CartridgeShape: View {
    let cartridge: InkCartridge
    @Environment(\.colorScheme) private var scheme

    private var bands: [Color] {
        cartridge.bands.map { bandColor($0, scheme) }
    }

    var body: some View {
        let fraction = Double(cartridge.percent ?? 0) / 100
        let known = cartridge.percent != nil
        ZStack {
            HStack(spacing: 3) {
                ForEach(Array(bands.enumerated()), id: \.offset) { _, c in
                    GeometryReader { g in
                        ZStack(alignment: .bottom) {
                            Rectangle().fill(Color.secondary.opacity(0.15))
                            if known {
                                Rectangle().fill(c).frame(height: g.size.height * fraction)
                                    .overlay(alignment: .top) {
                                        if cartridge.isBlack && fraction > 0 {
                                            Rectangle().fill(inkOutline).frame(height: 1)
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.top, 14)
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.5), lineWidth: 2)
                .padding(.top, 14)
            VStack {
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.5)).frame(width: 40, height: 10)
                Spacer()
            }
            if !known {
                Text("?").font(.system(size: 48, weight: .bold)).foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }
}
