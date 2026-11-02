// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import SwiftUI
import AppKit
import SmudgeCore

struct OverviewView: View {
    @ObservedObject var store: StatusStore
    var goTo: (SidebarItem) -> Void
    @State private var confirmCancel = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                header
                stateCard
                CardRow {
                    inkCard
                    jobCard
                }
                if store.scanner != .none { scannerCard }
                actionsCard
            }
            .padding(Space.page)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selected.isEmpty ? "No printer" : store.displayName).font(TypeScale.screenTitle)
                Text(model).font(TypeScale.secondary).foregroundStyle(.secondary)
            }
            Spacer()
            usbBadge
        }
    }

    private var model: String {
        guard let p = store.selectedInfo else { return "Printer model unknown" }
        return StatusStore.model(of: p)
    }

    private var usbBadge: some View {
        let usb = store.usbPresent
        let text = usb == true ? "USB connected" : usb == false ? "USB not found" : "USB not checked"
        let color: Color = usb == true ? .green : usb == false ? .red : .secondary
        return Label(text, systemImage: usb == false ? "cable.connector.slash" : "cable.connector")
            .font(TypeScale.secondary)
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.12)))
            .accessibilityLabel(text)
    }

    private var stateCard: some View {
        let h = store.health
        return HStack(alignment: .top, spacing: Space.l) {
            Image(systemName: h.symbol)
                .font(.system(size: 44))
                .foregroundStyle(h.color)
                .frame(width: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s) {
                Text(store.healthTitle).font(.largeTitle.bold())
                ForEach(store.healthDetails, id: \.self) { line in
                    Text(line).font(TypeScale.lead).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.queueStuck {
                    Button("Fix the print queue") { store.resetQueue() }.primaryAction()
                }
                if store.canCancelAlignment {
                    Button("Cancel alignment", role: .destructive) { confirmCancel = true }.secondaryAction()
                }
                if store.maint.cancelling {
                    HStack(spacing: Space.s) { ProgressView().controlSize(.small); Text("Asking the printer to cancel") }
                }
                if let o = store.maint.cancelOutcome {
                    Text(o).font(TypeScale.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.page)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(h.color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(h.color.opacity(0.35)))
        .confirmationDialog("Cancel the alignment?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel alignment", role: .destructive) { store.cancelAlignment() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("The printer stops the alignment. The page that was printed is not used.")
        }
    }

    private var inkCard: some View {
        Card(title: "Ink") {
            if let r = store.ink, !r.cartridges.isEmpty {
                ForEach(r.cartridges) { InkBar(cartridge: $0) }
            } else if let ink = store.status?.ink, !ink.isEmpty {
                ForEach(ink, id: \.name) { s in
                    HStack {
                        InkDot(isBlack: isBlackHex(s.colorHex) || s.name.localizedCaseInsensitiveContains("black"), hex: s.colorHex)
                        Text(s.name)
                        Spacer()
                        Text(s.level >= 0 ? "\(min(s.level, 100))%" : "unknown").foregroundStyle(.secondary)
                    }.font(TypeScale.secondary)
                }
            } else {
                Text(store.inkError ?? "Reading ink levels").font(TypeScale.secondary).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Show ink details") { goTo(.ink) }.buttonStyle(.link)
        }
    }

    private var jobCard: some View {
        Card(title: "Current job") {
            if let j = store.activeJob {
                Text(j.title).font(.body.weight(.medium)).lineLimit(2)
                Text("\(j.stateText), \(j.sizeKB) KB, \(j.user)").font(TypeScale.secondary).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Cancel job") { store.cancel(j) }.secondaryAction()
            } else {
                Text(store.idleJobText)
                    .font(TypeScale.secondary).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Show job history") { goTo(.jobs) }.buttonStyle(.link)
            }
        }
    }

    private var scannerCard: some View {
        Card(title: "Scanner") {
            switch store.scanner {
            case .scanning: Text("Scanning.").font(TypeScale.secondary).foregroundStyle(.secondary)
            case .off: Text("Scanner sharing is off. Turn it on in Settings.").font(TypeScale.secondary).foregroundStyle(.secondary)
            default: Text("Ready. Scan from Image Capture or Preview.").font(TypeScale.secondary).foregroundStyle(.secondary)
            }
            Button("Open Image Capture") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Image Capture.app"))
            }
            .secondaryAction()
        }
        .frame(maxHeight: 130)
    }

    private var actionsCard: some View {
        Card(title: "What do you want to do?") {
            HStack(spacing: Space.m) {
                Button { store.testPage() } label: {
                    Label("Print a test page", systemImage: "doc.text").frame(maxWidth: .infinity)
                }
                .primaryAction()
                .disabled(store.usbPresent == false)
                if store.maint.caps == nil || store.maint.supports(.clean) {
                    Button { store.maint.open(.clean) } label: {
                        Label("Clean print heads", systemImage: "sparkles").frame(maxWidth: .infinity)
                    }
                    .secondaryAction()
                    .disabled(!store.canMaintain || store.maint.caps == nil)
                }
                if store.maint.caps == nil || store.maint.supports(.align) {
                    Button { store.maint.open(.align) } label: {
                        Label("Line up print heads", systemImage: "arrow.left.and.right").frame(maxWidth: .infinity)
                    }
                    .secondaryAction()
                    .disabled(!store.canMaintain || store.maint.caps == nil)
                }
            }
            if let why = store.maintenanceBlockReason {
                Text(why).font(TypeScale.note).foregroundStyle(.secondary)
            }
            if let m = store.actionMessage {
                Text(m).font(TypeScale.note).foregroundStyle(.red)
            }
        }
    }
}
