// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

public enum PageResult: Equatable, Sendable {
    case file(URL, contentType: String)
    case noMorePages
    case failed
}

/// Holds the outcome of a job's page so NextDocument can wait for it.
public final class PageWaiter: @unchecked Sendable {
    private let cond = NSCondition()
    private var result: PageResult?

    public init() {}

    /// The outcome if the job has ended, without waiting.
    public var current: PageResult? {
        cond.lock(); defer { cond.unlock() }
        return result
    }

    /// Waits up to `timeout` seconds for the page to be ready, the job to have no page or the job to fail.
    /// Returns nil when none of that happened in time.
    public func wait(timeout: TimeInterval) -> PageResult? {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock(); defer { cond.unlock() }
        while result == nil {
            if !cond.wait(until: deadline) { break }
        }
        return result
    }

    func resolve(_ r: PageResult) {
        cond.lock()
        if result == nil { result = r }
        cond.broadcast()
        cond.unlock()
    }
}

/// The page of a passthrough job, read while the printer is still writing it.
public final class PageStream: @unchecked Sendable {
    public enum Step: Equatable, Sendable {
        case data(Data)
        /// Every byte was delivered and the job finished.
        case end
        /// The job was canceled or failed, or the file is gone.
        case failed
    }

    public let contentType: String
    private let file: URL
    private let waiter: PageWaiter
    private let pollInterval: TimeInterval
    private var handle: FileHandle?

    init(file: URL, contentType: String, waiter: PageWaiter, pollInterval: TimeInterval = 0.2) {
        self.file = file
        self.contentType = contentType
        self.waiter = waiter
        self.pollInterval = pollInterval
    }

    /// Blocks until there are new bytes (at most `limit`) or the stream is over. Call from one thread at a time.
    public func next(limit: Int = 1024 * 1024) -> Step {
        while true {
            // Read the outcome first: bytes written before the job ended are then still picked up.
            let outcome = waiter.current
            if handle == nil { handle = try? FileHandle(forReadingFrom: file) }
            if let handle, let data = try? handle.read(upToCount: limit), !data.isEmpty { return .data(data) }
            switch outcome {
            case .file?: return handle == nil ? .failed : .end
            case .noMorePages?, .failed?: return .failed
            case nil: Thread.sleep(forTimeInterval: pollInterval)
            }
        }
    }

    public func close() {
        try? handle?.close()
        handle = nil
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
    let waiter: PageWaiter
    private let flagLock = NSLock()
    private var cancelFlag = false

    init(id: Int, plan: ScanPlan, resolution: Int) {
        self.id = id
        self.plan = plan
        self.resolution = resolution
        self.waiter = PageWaiter()
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
