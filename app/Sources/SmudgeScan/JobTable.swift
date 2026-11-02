// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

public enum PageResult: Equatable, Sendable {
    case file(URL, contentType: String)
    case noMorePages
    case failed
}

/// What a request for a streamed page learns while it waits for the printer.
public enum GeometryWait: Equatable, Sendable {
    case ready(PageGeometry)
    /// The job ended before the printer reported a page size.
    case ended(PageResult)
    case timedOut
}

/// Holds the outcome of a job's page so NextDocument can wait for it.
public final class PageWaiter: @unchecked Sendable {
    private let cond = NSCondition()
    private var result: PageResult?
    private var geometry: PageGeometry?

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

    /// Waits up to `timeout` seconds for the printer to report the page size or the job to end.
    public func waitForGeometry(timeout: TimeInterval) -> GeometryWait {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock(); defer { cond.unlock() }
        while geometry == nil, result == nil {
            if !cond.wait(until: deadline) { break }
        }
        if let geometry { return .ready(geometry) }
        if let result { return .ended(result) }
        return .timedOut
    }

    func setGeometry(_ g: PageGeometry) {
        cond.lock()
        if geometry == nil { geometry = g }
        cond.broadcast()
        cond.unlock()
    }

    func resolve(_ r: PageResult) {
        cond.lock()
        if result == nil { result = r }
        cond.broadcast()
        cond.unlock()
    }
}

/// The TIFF of a streamed job: the header, then the page's rows as the printer writes them.
/// The length is known up front, so the reply carries a Content-Length.
public final class PageStream: @unchecked Sendable {
    public enum Step: Equatable, Sendable {
        case data(Data)
        /// Every byte was delivered.
        case end
        /// The job was canceled or failed, the page came up short or the file is gone.
        case failed
    }

    public let contentType: String
    /// Header plus pixel data.
    public let totalLength: Int
    private let layout: TIFFLayout
    private let file: URL
    private let waiter: PageWaiter
    private let pollInterval: TimeInterval
    private var handle: FileHandle?
    private var headerSent = false
    private var pending = Data()
    private var sourceRead = 0
    private var rowsSent = 0

    init(file: URL, layout: TIFFLayout, contentType: String, waiter: PageWaiter, pollInterval: TimeInterval = 0.2) {
        self.file = file
        self.layout = layout
        self.contentType = contentType
        self.waiter = waiter
        self.pollInterval = pollInterval
        totalLength = layout.totalLength
    }

    /// Blocks until there are new bytes or the stream is over. Call from one thread at a time.
    public func next(limit: Int = 1024 * 1024) -> Step {
        if !headerSent {
            headerSent = true
            return .data(layout.header)
        }
        let rowSize = layout.geometry.bytesPerLine
        let sourceTotal = rowSize * layout.geometry.height
        while true {
            if rowsSent == layout.geometry.height { return .end }
            // Read the outcome first: bytes written before the job ended are then still picked up.
            let outcome = waiter.current
            if handle == nil { handle = try? FileHandle(forReadingFrom: file) }
            if let handle, let data = try? handle.read(upToCount: min(limit, sourceTotal - sourceRead)), !data.isEmpty {
                sourceRead += data.count
                pending.append(data)
                let rows = pending.count / rowSize
                if rows == 0 { continue }
                let whole = pending.prefix(rows * rowSize)
                let out = layout.convert(Data(whole))
                pending = Data(pending.dropFirst(rows * rowSize))
                rowsSent += rows
                return .data(out)
            }
            switch outcome {
            case .file?, .noMorePages?, .failed?: return .failed
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
