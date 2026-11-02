// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import SwiftUI
import SmudgeCore

struct JobsView: View {
    @ObservedObject var store: StatusStore
    @State private var selection = Set<PrintJob.ID>()
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", active = "Active", completed = "History"
        var id: String { rawValue }
    }

    private var shown: [PrintJob] {
        switch filter {
        case .all: return store.jobs
        case .active: return store.jobs.filter(\.isActive)
        case .completed: return store.jobs.filter { !$0.isActive }
        }
    }

    private var selectedActive: [Int] {
        store.jobs.filter { selection.contains($0.id) && $0.isActive }.map(\.id)
    }

    var body: some View {
        Table(shown, selection: $selection) {
            TableColumn("Title") { j in Text(j.title).lineLimit(1) }
            TableColumn("State") { j in
                Text(j.stateText).foregroundStyle(color(j))
            }.width(min: 80, ideal: 110)
            TableColumn("Size") { j in
                Text(ByteCountFormatter.string(fromByteCount: Int64(j.sizeKB) * 1024, countStyle: .file))
                    .monospacedDigit()
            }.width(min: 60, ideal: 80)
            TableColumn("Submitted") { j in
                Text(j.time.formatted(date: .abbreviated, time: .shortened))
            }.width(min: 120, ideal: 160)
        }
        .overlay {
            if shown.isEmpty {
                ContentUnavailableView("No jobs", systemImage: "tray",
                                       description: Text(filter == .active ? "Nothing is printing." : "No jobs have been sent to this printer yet."))
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }
            ToolbarItem {
                Button { store.cancel(ids: selectedActive) } label: { Label("Cancel selected jobs", systemImage: "xmark.circle") }
                    .disabled(selectedActive.isEmpty)
                    .help("Cancel the selected active jobs")
            }
            ToolbarItem {
                Button { store.cancelAll() } label: { Label("Cancel all", systemImage: "xmark.bin") }
                    .disabled(store.activeJob == nil)
                    .help("Cancel all active jobs")
            }
            ToolbarItem {
                let paused = store.status?.stateCode == 5
                Button { store.togglePause() } label: {
                    Label(paused ? "Resume printing" : "Pause printing", systemImage: paused ? "play.fill" : "pause.fill")
                }
                .help(paused ? "Let the printer carry on" : "Hold all jobs for now")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let m = store.actionMessage {
                Text(m).font(TypeScale.note).foregroundStyle(.red).padding(Space.page).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func color(_ j: PrintJob) -> Color {
        switch j.stateCode {
        case 8: return .red
        case 9: return .green
        case 7: return .secondary
        default: return j.isActive ? .blue : .primary
        }
    }
}
