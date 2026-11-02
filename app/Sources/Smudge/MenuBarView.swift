// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import SwiftUI
import AppKit
import SmudgeCore

struct MenuBarView: View {
    @ObservedObject var store: StatusStore
    @Environment(\.openWindow) private var openWindow
    @State private var confirmCancel = false

    var body: some View {
        let h = store.health
        VStack(alignment: .leading, spacing: Space.m) {
            PrinterMenu(store: store)
            HStack(spacing: 10) {
                Image(systemName: h.symbol).font(.title2).foregroundStyle(h.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.healthTitle).font(.headline)
                    Text(store.healthDetails.first ?? "").font(TypeScale.note).foregroundStyle(.secondary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)
            Divider()
            if let r = store.ink, !r.cartridges.isEmpty {
                VStack(spacing: Space.s) { ForEach(r.cartridges) { InkBar(cartridge: $0) } }
            } else {
                Text(store.inkError ?? "Reading ink levels").font(.caption).foregroundStyle(.secondary)
            }
            if let j = store.activeJob {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text(j.title).font(.callout).lineLimit(1)
                    Text("\(j.stateText), \(j.sizeKB) KB").font(.caption).foregroundStyle(.secondary)
                }
            }
            if store.canCancelAlignment || store.maint.cancelling || store.maint.cancelOutcome != nil {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if store.maint.cancelling {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Asking the printer to cancel").font(.callout) }
                    } else if confirmCancel {
                        Text("Stop the alignment on the printer?").font(TypeScale.secondary)
                        HStack {
                            Button("Cancel alignment", role: .destructive) { confirmCancel = false; store.cancelAlignment() }
                            Button("Keep going") { confirmCancel = false }
                        }
                    } else if store.canCancelAlignment {
                        Button("Cancel alignment", role: .destructive) { confirmCancel = true }
                    }
                    if let o = store.maint.cancelOutcome {
                        Text(o).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                Button("Open window") {
                    openWindow(id: "main")
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .primaryAction()
                .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.secondaryAction()
            }
        }
        .padding(Space.page)
        .frame(width: 360)
        .onAppear { Task { await store.refreshInk() } }
    }
}
