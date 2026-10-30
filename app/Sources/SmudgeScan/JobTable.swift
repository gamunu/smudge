// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

public enum PageResult: Equatable, Sendable {
    case file(URL, contentType: String)
    case noMorePages
    case failed
}

/// Lets the HTTP layer hold NextDocument open while the scan runs.
public final class PageWaiter: @unchecked Sendable {
    private let cond = NSCondition()
    private var result: PageResult?

    public init() {}

    /// Blocks until the page is ready, the job has no page or the job failed.
    public func wait() -> PageResult {
        cond.lock(); defer { cond.unlock() }
        while result == nil { cond.wait() }
        return result!
    }

    func resolve(_ r: PageResult) {
        cond.lock()
        if result == nil { result = r }
        cond.broadcast()
        cond.unlock()
    }
}

/// One scan job as the router tracks it. Fields change only under the router's lock, except `cancelled`.
final class ScanJobRecord: @unchecked Sendable {
    let id: Int
    let uuid = UUID()
    let created = Date()
    var finished: Date?
    var state = ESCLJobInfo.State.processing
    var imagesCompleted = 0
    let plan: ScanPlan
    let resolution: Int
    var pageFile: URL?
    var nextDocumentServed = false
    let waiter = PageWaiter()
    private let flagLock = NSLock()
    private var cancelFlag = false

    init(id: Int, plan: ScanPlan, resolution: Int) {
        self.id = id
        self.plan = plan
        self.resolution = resolution
    }

    var cancelled: Bool {
        get { flagLock.lock(); defer { flagLock.unlock() }; return cancelFlag }
        set { flagLock.lock(); cancelFlag = newValue; flagLock.unlock() }
    }

    func info(now: Date) -> ESCLJobInfo {
        ESCLJobInfo(id: id, uuid: uuid, age: max(0, Int(now.timeIntervalSince(created))), imagesCompleted: imagesCompleted,
                    imagesToTransfer: state == .processing ? 1 : 0, state: state)
    }
}

/// Job records and their lifetimes. Not thread safe: the router serializes access.
public final class JobTable {
    private var jobs: [Int: ScanJobRecord] = [:]
    private var nextID = 1

    public init() {}

    func create(plan: ScanPlan, resolution: Int) -> ScanJobRecord {
        let j = ScanJobRecord(id: nextID, plan: plan, resolution: resolution)
        nextID += 1
        jobs[j.id] = j
        return j
    }

    func job(_ id: Int) -> ScanJobRecord? { jobs[id] }

    func infos(now: Date) -> [ESCLJobInfo] { jobs.values.sorted { $0.id < $1.id }.map { $0.info(now: now) } }

    /// Drops finished jobs that ended more than `age` seconds ago and returns their page files.
    func expire(olderThan age: TimeInterval, now: Date) -> [URL] {
        var files: [URL] = []
        for (id, j) in jobs {
            guard let done = j.finished, now.timeIntervalSince(done) >= age else { continue }
            if let f = j.pageFile { files.append(f) }
            jobs[id] = nil
        }
        return files
    }

    func allPageFiles() -> [URL] { jobs.values.compactMap(\.pageFile) }
}
