// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import SwiftUI
import SmudgeCore

func inkColor(_ hex: String?) -> Color {
    guard var h = hex?.trimmingCharacters(in: .whitespaces), h.hasPrefix("#") else { return .gray }
    h.removeFirst()
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return .gray }
    return Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255,
                 blue: Double(v & 255) / 255)
}

let inkCyan = Color(red: 0.0, green: 0.68, blue: 0.93)
let inkMagenta = Color(red: 0.9, green: 0.1, blue: 0.55)
let inkYellow = Color(red: 1.0, green: 0.85, blue: 0.0)

/// Near-black ink. Pure black vanishes on a dark background, so dark mode uses a very dark
/// grey and every black swatch gets an outline (see `inkOutline`).
func blackInk(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(white: 0.07) : .black
}

/// Outline that keeps a black swatch visible on both backgrounds.
let inkOutline = Color.primary.opacity(0.5)

func isBlackHex(_ hex: String?) -> Bool {
    guard var h = hex?.trimmingCharacters(in: .whitespaces), h.hasPrefix("#") else { return false }
    h.removeFirst()
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return false }
    let r = (v >> 16) & 255, g = (v >> 8) & 255, b = v & 255
    return r < 0x50 && g < 0x50 && b < 0x50
}

/// Colored dot for one ink. Multi-color cartridges are split into their bands.
struct InkDot: View {
    var isBlack: Bool = false
    var bands: [InkBand] = []
    var hex: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if bands.count > 1 {
                VStack(spacing: 0) {
                    ForEach(Array(bands.enumerated()), id: \.offset) { _, b in bandColor(b, scheme) }
                }
                .clipShape(Circle())
            } else if isBlack {
                Circle().fill(blackInk(scheme))
            } else {
                Circle().fill(inkColor(hex))
            }
        }
        .frame(width: 10, height: 10)
        .overlay(Circle().strokeBorder(inkOutline, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// Fill color of one band. Black adapts to the color scheme, the rest are fixed.
func bandColor(_ band: InkBand, _ scheme: ColorScheme) -> Color {
    switch band {
    case .cyan: return inkCyan
    case .magenta: return inkMagenta
    case .yellow: return inkYellow
    case .black: return blackInk(scheme)
    default: return inkColor(band.hex)
    }
}

/// Bar with an empty track. Black ink is a near-black fill with an outline, tri-color is three
/// stacked cyan, magenta and yellow stripes.
struct InkLevelBar: View {
    let cartridge: InkCartridge
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let fraction = Double(min(max(cartridge.percent ?? 0, 0), 100)) / 100
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                if cartridge.percent != nil, fraction > 0 {
                    fill.frame(width: max(g.size.height, g.size.width * fraction))
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(cartridge.isBlack ? inkOutline : .clear, lineWidth: 1)
                            .frame(width: max(g.size.height, g.size.width * fraction)),
                                 alignment: .leading)
                }
                Capsule().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1)
            }
        }
        .frame(height: 10)
    }

    @ViewBuilder private var fill: some View {
        if cartridge.isMulti {
            VStack(spacing: 0) { ForEach(Array(cartridge.bands.enumerated()), id: \.offset) { _, b in bandColor(b, scheme) } }
        } else {
            bandColor(cartridge.bands.first ?? .other, scheme)
        }
    }
}

/// Small horizontal bar used in the overview and the menu bar popover.
struct InkBar: View {
    let cartridge: InkCartridge
    var body: some View {
        HStack(spacing: 8) {
            InkDot(isBlack: cartridge.isBlack, bands: cartridge.bands, hex: cartridge.colorHex)
            Text(cartridge.name).frame(width: 72, alignment: .leading)
            InkLevelBar(cartridge: cartridge)
            Text(cartridge.percentText).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .font(TypeScale.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cartridge.spoken)
    }
}
