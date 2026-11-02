// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import SwiftUI
import SmudgeCore

/// The guided sheet for one maintenance task. Fixed size, instructions on the left and a big
/// picture on the right, slim numbered progress at the top.
struct MaintenanceSheet: View {
    @ObservedObject var store: StatusStore
    @ObservedObject var maint: MaintenanceController
    @State private var confirmCancel = false

    static let size = CGSize(width: 680, height: 560)
    private let artWidth: CGFloat = 270

    var body: some View {
        if let job = maint.job {
            VStack(alignment: .leading, spacing: Space.l) {
                header(job)
                Divider()
                content(job)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                footer(job)
            }
            .padding(Space.page)
            .frame(width: Self.size.width, height: Self.size.height)
            .fixedSize()
            .interactiveDismissDisabled(maint.isBusy)
            .confirmationDialog("Cancel this job on the printer?", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("Cancel job", role: .destructive) { Task { await maint.cancelFlow() } }
                Button("Keep going", role: .cancel) {}
            } message: {
                Text("The printer stops what it is doing. Ink already used is not recovered.")
            }
        }
    }

    private var isFailed: Bool { if case .failed = maint.stage { return true } else { return false } }

    private func header(_ job: MaintenanceJob) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: job.symbol).font(.title2).foregroundStyle(Color.accentColor)
            Text(job.title).font(TypeScale.screenTitle)
            Spacer(minLength: Space.l)
            ProgressDots(steps: MaintenanceController.steps(for: job, alignment: maint.caps?.alignment), current: maint.reached, failed: isFailed)
        }
    }

    // MARK: content

    @ViewBuilder private func content(_ job: MaintenanceJob) -> some View {
        switch maint.stage {
        case .prepare: prepare(job)
        case .starting:
            guide(art: .working) {
                Text("Talking to the printer").font(TypeScale.heroTitle)
                HStack(spacing: Space.m) { ProgressView().controlSize(.small); Text("One moment.").font(TypeScale.lead) }
            }
        case .cancelling:
            guide(art: .working) {
                Text("Stopping the printer").font(TypeScale.heroTitle)
                HStack(spacing: Space.m) { ProgressView().controlSize(.small); Text("This can take up to 20 seconds.").font(TypeScale.lead) }
            }
        case .cancelled(let msg): cancelled(msg)
        case .running: running(job)
        case .awaitScan: scanSteps(scanning: false)
        case .scanning: scanSteps(scanning: true)
        case .done: done(job)
        case .failed(let msg): failed(msg)
        }
    }

    /// Text on the left, a big picture on the right.
    private func guide<Body: View>(art: IllustrationScene, @ViewBuilder text: () -> Body) -> some View {
        HStack(alignment: .center, spacing: Space.page) {
            VStack(alignment: .leading, spacing: Space.m) { text() }
                .frame(width: Self.size.width - 2 * Space.page - artWidth - Space.page, alignment: .leading)
                .fixedSize(horizontal: true, vertical: true)
            Illustration(scene: art).frame(width: artWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func prepare(_ job: MaintenanceJob) -> some View {
        guide(art: .loadPaper) {
            Text("Put plain paper in the printer").font(TypeScale.heroTitle)
            Text("Open the tray at the back and slide in a few sheets of plain white paper.")
                .font(TypeScale.lead)
            Text(job.summary(for: maint.caps?.alignment)).font(TypeScale.secondary).foregroundStyle(.secondary)
            switch job {
            case .deepClean:
                Banner { Label("Deep clean uses more ink. Try a normal clean first.", systemImage: "drop.fill") }
            case .align:
                if maint.caps?.alignment == .automatic {
                    Text("The printer lines up the print heads by itself. It uses one sheet of paper.").font(TypeScale.secondary).foregroundStyle(.secondary)
                } else {
                    Banner(tint: .accentColor) { Label("You will put the printed page on the scanner. Stay near the printer.", systemImage: "scanner") }
                }
            default:
                Text("This uses a little ink and one sheet of paper.").font(TypeScale.secondary).foregroundStyle(.secondary)
            }
            if let why = store.maintenanceBlockReason {
                Banner { Label(why, systemImage: "exclamationmark.circle") }
            }
        }
    }

    private func running(_ job: MaintenanceJob) -> some View {
        let a = maint.attention
        return guide(art: attentionScene(a) ?? (job == .clean || job == .deepClean ? .working : .printing)) {
            if let a {
                Text(a.title).font(TypeScale.heroTitle)
                Text(a.detail).font(TypeScale.lead)
            } else {
                HStack(spacing: Space.m) {
                    ProgressView().controlSize(.small)
                    Text(runningTitle(job)).font(TypeScale.heroTitle)
                }
                Text("Please wait. You do not need to do anything.").font(TypeScale.lead)
            }
            printerState
        }
    }

    private func attentionScene(_ a: Attention?) -> IllustrationScene? {
        switch a {
        case .loadPaper: return .loadPaper
        case .closeDoor: return .closeDoor
        case .other: return .working
        case nil: return nil
        }
    }

    private func runningTitle(_ job: MaintenanceJob) -> String {
        switch job {
        case .clean, .deepClean: return "Cleaning the print heads"
        case .diagnostics: return "Printing the test page"
        case .align: return "Printing the alignment page"
        }
    }

    /// One plain line, with the raw values folded away.
    private var printerState: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text("The printer says:").foregroundStyle(.secondary)
                Text(Maintenance.liveText(maint.categories)).fontWeight(.medium)
            }
            .font(TypeScale.secondary)
            .accessibilityElement(children: .combine)
            Details {
                Text("Status: \(maint.categories.isEmpty ? "none yet" : maint.categories.joined(separator: ", "))")
                if let c = maint.calState { Text("Alignment: \(c)") }
            }
        }
    }

    // MARK: alignment scan

    private func scanSteps(scanning: Bool) -> some View {
        let scenes: [(IllustrationScene, String)] = [
            (.liftLid, "Lift the lid"),
            (.placePage, "Put the page face down in the corner with the marker"),
            (.closeLid, "Close the lid"),
            (.pressColorCopy, "Press Color Copy once"),
        ]
        return VStack(alignment: .leading, spacing: Space.l) {
            if scanning {
                HStack(spacing: Space.m) {
                    ProgressView().controlSize(.small)
                    Text("The printer is scanning the page").font(TypeScale.heroTitle)
                }
                Text("Keep the lid closed until it stops.").font(TypeScale.lead)
            } else {
                Text("The page is ready. Scan it now.").font(TypeScale.heroTitle)
                Text("Do these four things in order.").font(TypeScale.lead)
            }
            HStack(alignment: .top, spacing: Space.m) {
                ForEach(Array(scenes.enumerated()), id: \.offset) { i, s in
                    StepPicture(number: i + 1, scene: s.0, caption: s.1, mode: scanMode(i, scanning: scanning))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if let a = maint.attention {
                Banner { Label("\(a.title). \(a.detail)", systemImage: a.symbol) }
            }
            printerState
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    /// The printer only tells us it is waiting for the page, or that it is scanning.
    private func scanMode(_ i: Int, scanning: Bool) -> StepPicture.Mode {
        if scanning { return i < 3 ? .done : .current }
        return i == 0 ? .current : .normal
    }

    // MARK: finished

    @ViewBuilder private func done(_ job: MaintenanceJob) -> some View {
        switch job {
        case .clean, .deepClean:
            guide(art: .done) {
                Text("Cleaning is finished").font(TypeScale.heroTitle)
                Text("This printer does not print a page after cleaning. Check the quality to see if it worked.")
                    .font(TypeScale.lead)
                notes
            }
        case .diagnostics:
            VStack(alignment: .leading, spacing: Space.l) {
                Text("The page is printed. How did it look?").font(TypeScale.heroTitle)
                HStack(alignment: .top, spacing: Space.page) {
                    VStack(alignment: .leading, spacing: Space.l) {
                        outcome("checkmark.circle.fill", .green, "Strong colors and dark black text", "All good. You are done.")
                        outcome("sparkles", .orange, "Faint text or gaps in the colors", "Run a deep clean.")
                        outcome("exclamationmark.triangle.fill", .orange, "Still faint after a deep clean",
                                "Wipe the copper contacts on the cartridge with a dry, soft cloth.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: Space.s) {
                        Illustration(scene: .cleanContacts).frame(width: artWidth - 40)
                        Text("Wipe the copper contacts").font(TypeScale.secondary.weight(.medium))
                    }
                }
                notes
            }
            .frame(maxHeight: .infinity, alignment: .center)
        case .align:
            guide(art: .done) {
                Text("Alignment is finished").font(TypeScale.heroTitle)
                if maint.caps?.alignment == .automatic {
                    Text("The printer lined up its print heads and is ready.").font(TypeScale.lead)
                } else {
                    Text("The printer scanned the page and is ready.").font(TypeScale.lead)
                    Text("If the Attention light on the printer blinks, it did not work. Put the page back on the glass and try again.")
                        .font(TypeScale.secondary).foregroundStyle(.secondary)
                }
                notes
            }
        }
    }

    @ViewBuilder private var notes: some View {
        if let n = maint.note { Text(n).font(TypeScale.secondary).foregroundStyle(.secondary) }
    }

    private func outcome(_ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: symbol).font(.title3).foregroundStyle(color).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TypeScale.lead.weight(.semibold))
                Text(detail).font(TypeScale.secondary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func failed(_ msg: String) -> some View {
        guide(art: .working) {
            Label("That did not work", systemImage: "exclamationmark.triangle.fill")
                .font(TypeScale.heroTitle).foregroundStyle(.orange)
            let parts = msg.components(separatedBy: "\n")
            Text(parts[0]).font(TypeScale.lead).fixedSize(horizontal: false, vertical: true)
            if parts.count > 1 { Details { ForEach(Array(parts.dropFirst()), id: \.self) { Text($0) } } }
        }
    }

    private func isDetail(_ line: String) -> Bool { line.hasPrefix("PUT ") || line.hasPrefix("Details: ") }

    private func cancelled(_ msg: String) -> some View {
        let lines = msg.components(separatedBy: "\n")
        return guide(art: .working) {
            Label("The printer was told to stop", systemImage: "xmark.circle.fill").font(TypeScale.heroTitle)
            ForEach(lines.filter { !isDetail($0) }, id: \.self) { Text($0).font(TypeScale.lead).fixedSize(horizontal: false, vertical: true) }
            if lines.contains(where: isDetail) {
                Details { ForEach(lines.filter(isDetail), id: \.self) { Text($0) } }
            }
        }
    }

    // MARK: footer

    @ViewBuilder private func footer(_ job: MaintenanceJob) -> some View {
        HStack(spacing: Space.m) {
            switch maint.stage {
            case .prepare:
                Spacer()
                Button("Cancel") { maint.close() }.secondaryAction().keyboardShortcut(.cancelAction)
                Button(job.startLabel) { maint.begin() }
                    .primaryAction()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.canMaintain)
            case .starting, .running, .awaitScan, .scanning:
                Text("Closing this window does not stop the printer.")
                    .font(TypeScale.note).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Stop watching") { maint.close() }.secondaryAction()
                Button("Cancel", role: .destructive) { confirmCancel = true }.secondaryAction()
            case .cancelling:
                ProgressView().controlSize(.small)
                Spacer()
            case .cancelled:
                Spacer()
                Button("Close") { maint.close() }.primaryAction().keyboardShortcut(.defaultAction)
            case .done:
                Spacer()
                if job == .clean || job == .deepClean {
                    Button("Close") { maint.close() }.secondaryAction().keyboardShortcut(.cancelAction)
                    Button("Check print quality") { maint.open(.diagnostics) }
                        .primaryAction().keyboardShortcut(.defaultAction)
                } else {
                    Button("Close") { maint.close() }.primaryAction().keyboardShortcut(.defaultAction)
                }
            case .failed:
                Spacer()
                Button("Close") { maint.close() }.secondaryAction().keyboardShortcut(.cancelAction)
                Button("Try again") { maint.retry() }.primaryAction().keyboardShortcut(.defaultAction)
            }
        }
        .frame(height: 32)
    }
}

/// Slim numbered progress. Only the current step name is shown, so no label can wrap or hyphenate.
struct ProgressDots: View {
    let steps: [String]
    let current: Int
    var failed = false

    var body: some View {
        let index = min(current, steps.count - 1)
        HStack(spacing: Space.s) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, _ in
                if i > 0 { Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 14, height: 2) }
                dot(i)
            }
            Text(steps[index])
                .font(TypeScale.secondary.weight(.semibold))
                .lineLimit(1).fixedSize()
                .padding(.leading, Space.xs)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index + 1) of \(steps.count): \(steps[index])")
    }

    private func dot(_ i: Int) -> some View {
        let finished = i < current || (i == current && current == steps.count - 1 && !failed)
        return ZStack {
            Circle().fill(fill(i)).frame(width: 22, height: 22)
            if finished {
                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
            } else if i == current && failed {
                Image(systemName: "exclamationmark").font(.caption.bold()).foregroundStyle(.white)
            } else {
                Text("\(i + 1)").font(.caption.bold()).foregroundStyle(i == current ? .white : .secondary)
            }
        }
    }

    private func fill(_ i: Int) -> Color {
        if i == current && failed { return .orange }
        if i < current { return .green }
        if i == current { return .accentColor }
        return Color.secondary.opacity(0.2)
    }
}
