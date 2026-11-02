// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

/// Hidden launch argument `--preview-step <name>` opens the maintenance sheet on a fixed step
/// with made-up state. Nothing talks to the printer in this mode. Used for screenshots.
public enum PreviewMode {
    public struct Spec: Sendable {
        var job: MaintenanceJob
        var stage: FlowStage
        var reached: Int
        var attention: Attention?
        var categories: [String] = []
        var calState: String?
    }

    public static let spec: Spec? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--preview-step"), i + 1 < a.count else { return nil }
        switch a[i + 1].lowercased() {
        case "starting":
            return Spec(job: .clean, stage: .starting, reached: 1)
        case "cleaning":
            return Spec(job: .clean, stage: .running, reached: 1, categories: ["processing"])
        case "printing":
            return Spec(job: .diagnostics, stage: .running, reached: 1, categories: ["processing"])
        case "paper":
            return Spec(job: .diagnostics, stage: .running, reached: 1, attention: .loadPaper, categories: ["trayEmptyOrOpen"])
        case "door":
            return Spec(job: .clean, stage: .running, reached: 1, attention: .closeDoor, categories: ["closeDoorOrCover"])
        case "scan":
            return Spec(job: .align, stage: .awaitScan, reached: 2, categories: ["ready"], calState: "ScanRequested")
        case "scanning":
            return Spec(job: .align, stage: .scanning, reached: 2, categories: ["processing"], calState: "Scanning")
        case "done-clean":
            return Spec(job: .clean, stage: .done, reached: 2)
        case "diagnostics", "check":
            return Spec(job: .diagnostics, stage: .done, reached: 2)
        case "done-align":
            return Spec(job: .align, stage: .done, reached: 3)
        case "failed":
            return Spec(job: .align, stage: .failed("The printer stopped answering."), reached: 1)
        case "cancelled":
            return Spec(job: .clean, stage: .cancelled("The printer has no active job to cancel.\nPrinter status: Ready."), reached: 1)
        default:
            return Spec(job: .clean, stage: .prepare, reached: 0)
        }
    }()

    public static var isActive: Bool { spec != nil }
}
