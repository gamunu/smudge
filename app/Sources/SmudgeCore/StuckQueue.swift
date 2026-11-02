// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

/// CUPS can keep a queue at "processing" after its job is gone. The queue counts
/// as stuck when it has said "processing" with no active job for longer than
/// `staleSeconds` and the printer itself does not report any activity.
struct StuckQueueRule {
    static let staleSeconds = 10.0

    private var staleSince: Date?

    /// Returns true when the queue looks stuck.
    mutating func update(stateCode: Int?, hasActiveJob: Bool, printerBusy: Bool, now: Date) -> Bool {
        if stateCode == 4 && !hasActiveJob {
            if staleSince == nil { staleSince = now }
        } else {
            staleSince = nil
        }
        let stale = staleSince.map { now.timeIntervalSince($0) > Self.staleSeconds } ?? false
        return stale && !printerBusy
    }
}
