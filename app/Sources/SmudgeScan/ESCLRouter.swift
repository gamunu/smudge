// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

public struct RouterResponse {
    public enum Body {
        case none
        case data(Data)
        case file(URL, contentType: String)
        /// A TIFF of known length, sent as the printer scans it.
        case stream(PageStream)
    }

    public var status: Int
    public var headers: [String: String]
    public var body: Body

    public init(status: Int, headers: [String: String] = [:], body: Body = .none) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// eSCL for one scanner: method, path and body in, response out. Knows nothing about sockets.
public final class ESCLRouter: @unchecked Sendable {
    /// How long a finished job stays in the status list (the spec leaves this open).
    public static let finishedJobLifetime: TimeInterval = 300
    /// Age after which a page file in the work folder counts as left over from an earlier run.
    static let staleFileAge: TimeInterval = 60 * 60
    /// The scanner state is read at most this often while no job runs.
    static let stateCacheSeconds: TimeInterval = 3

    private let device: ScanDevice
    private let name: String
    private let uuid: UUID
    private let serial: String
    private let tone: ToneCalibration
    private let workDir: URL
    private let onActivity: @Sendable (Bool) -> Void
    private let blocked: @Sendable () -> Bool
    private let pageWait: TimeInterval

    private let lock = NSLock()
    private let idle = NSCondition()
    private let jobs = JobTable()
    private var running: ScanJobRecord?
    private var cachedState: (value: String, at: Date)?
    private let queue = DispatchQueue(label: "escl.scan", qos: .userInitiated)

    public init(device: ScanDevice, name: String, uuid: UUID, serial: String, tone: ToneCalibration, workDir: URL,
                onActivity: @escaping @Sendable (Bool) -> Void, blocked: @escaping @Sendable () -> Bool = { false },
                pageWait: TimeInterval = 20) {
        self.device = device
        self.name = name
        self.uuid = uuid
        self.serial = serial
        self.tone = tone
        self.workDir = workDir
        self.onActivity = onActivity
        self.blocked = blocked
        self.pageWait = pageWait
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        removeStaleFiles()
    }

    /// Job ids start at 1 in every run, so files are named by the job's UUID. A stream then can
    /// only ever read the page its own job writes, never one an earlier run left behind.
    private func pageFile(_ job: ScanJobRecord) -> URL {
        workDir.appendingPathComponent("job-\(job.uuid.uuidString).page")
    }

    /// Drops pages earlier runs left behind. Recent files may belong to another running agent.
    private func removeStaleFiles() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Self.staleFileAge)
        let files = (try? fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files where f.lastPathComponent.hasPrefix("job-") {
            let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: f) }
        }
    }

    // MARK: routes

    public func handle(method: String, path rawPath: String, body: Data) -> RouterResponse {
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        expireFinishedJobs(olderThan: Self.finishedJobLifetime)
        let parts = path.split(separator: "/").map(String.init)
        guard parts.first == "eSCL" else { return notFound() }
        switch (method, parts.count) {
        case ("GET", 2) where parts[1] == "ScannerCapabilities":
            return xml(ESCLCaps.xml(caps: device.caps, name: name, uuid: uuid, serial: serial))
        case ("GET", 2) where parts[1] == "ScannerStatus":
            return xml(status())
        case ("POST", 2) where parts[1] == "ScanJobs":
            return createJob(body)
        case ("GET", 4) where parts[1] == "ScanJobs" && parts[3] == "NextDocument":
            return nextDocument(Int(parts[2]))
        case ("DELETE", 3) where parts[1] == "ScanJobs":
            return deleteJob(Int(parts[2]))
        default:
            return notFound()
        }
    }

    /// Cancels the running job and removes the page files.
    public func shutdown() {
        lock.lock()
        running?.cancelled = true
        lock.unlock()
        waitUntilIdle()
        lock.lock()
        let files = jobs.allPageFiles()
        lock.unlock()
        for f in files { try? FileManager.default.removeItem(at: f) }
    }

    /// True while a scan is running or being rendered.
    public var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return running != nil }

    func waitUntilIdle() {
        idle.lock(); defer { idle.unlock() }
        while isBusy { idle.wait(until: Date().addingTimeInterval(0.05)) }
    }

    func expireFinishedJobs(olderThan age: TimeInterval) {
        lock.lock()
        let files = jobs.expire(olderThan: age, now: Date())
        lock.unlock()
        for f in files { try? FileManager.default.removeItem(at: f) }
    }

    // MARK: handlers

    private func notFound() -> RouterResponse { RouterResponse(status: 404) }

    private func xml(_ s: String) -> RouterResponse {
        RouterResponse(status: 200, headers: ["Content-Type": "text/xml"], body: .data(Data(s.utf8)))
    }

    private func status() -> String {
        lock.lock()
        let busy = running != nil
        let list = jobs.infos(now: Date())
        let cached = cachedState
        lock.unlock()
        if busy { return ESCLStatus.xml(state: "Processing", jobs: list) }

        var state: String
        if let cached, Date().timeIntervalSince(cached.at) < Self.stateCacheSeconds {
            state = cached.value
        } else {
            do { state = try device.scannerState() == "Idle" ? "Idle" : "Processing" } catch { state = "Stopped" }
            lock.lock(); cachedState = (state, Date()); lock.unlock()
        }
        return ESCLStatus.xml(state: state, jobs: list)
    }

    private func createJob(_ body: Data) -> RouterResponse {
        guard let parsed = ESCLScanSettings.parse(body), let settings = try? parsed.validated(against: device.caps) else {
            return RouterResponse(status: 400)
        }
        lock.lock()
        if running != nil || blocked() { lock.unlock(); return RouterResponse(status: 503, headers: ["Retry-After": "5"]) }
        // Reserve the scanner before leaving the lock, so a second POST sees it taken.
        let plan = ScanPlanner.plan(settings, caps: device.caps, tone: tone)
        let job = jobs.create(plan: plan, resolution: settings.resolution)
        running = job
        cachedState = nil
        lock.unlock()

        let ready = (try? device.scannerState()) == "Idle"
        if !ready {
            lock.lock()
            job.state = .aborted; job.finished = Date(); running = nil
            lock.unlock()
            job.waiter.resolve(.failed)
            idle.lock(); idle.broadcast(); idle.unlock()
            return RouterResponse(status: 503, headers: ["Retry-After": "5"])
        }

        onActivity(true)
        queue.async { [self] in run(job) }
        return RouterResponse(status: 201, headers: ["Location": "/eSCL/ScanJobs/\(job.id)"])
    }

    private func run(_ job: ScanJobRecord) {
        let raw = pageFile(job)
        let out = workDir.appendingPathComponent("job-\(job.uuid.uuidString).out")
        var result: PageResult = .failed
        var state = ESCLJobInfo.State.aborted
        var completed = 0
        var keep: URL?
        do {
            let outcome = try device.scan(job.plan.request, to: raw, isCancelled: { job.cancelled },
                                          onPageReady: { job.waiter.setGeometry($0) })
            switch outcome {
            case .page:
                if job.cancelled {
                    state = .canceled; result = .noMorePages
                } else if job.plan.streamsTIFF {
                    keep = raw
                    state = .completed; completed = 1
                    result = .file(raw, contentType: job.plan.output.rawValue)
                } else {
                    try ImagePipeline.render(page: raw, plan: job.plan, resolution: job.resolution, to: out)
                    keep = out
                    state = .completed; completed = 1
                    result = .file(out, contentType: job.plan.output.rawValue)
                }
            case .noDocument: state = .completed; result = .noMorePages
            case .canceledByClient: state = .canceled; result = .noMorePages
            case .canceledByDevice: state = .aborted; result = .failed
            }
        } catch {
            state = job.cancelled ? .canceled : .aborted
            result = job.cancelled ? .noMorePages : .failed
        }
        if keep != raw { try? FileManager.default.removeItem(at: raw) }

        lock.lock()
        job.state = state
        job.imagesCompleted = completed
        job.pageFile = keep
        job.finished = Date()
        running = nil
        cachedState = nil
        lock.unlock()
        job.waiter.resolve(result)
        onActivity(false)
        idle.lock(); idle.broadcast(); idle.unlock()
    }

    /// A streamed job answers as soon as the printer reports the page size and sends the TIFF while the
    /// printer scans, because Image Capture drops a response that stays silent for about a minute. Other
    /// jobs wait for the page and ask the client to retry when it takes too long. The job counts as served
    /// once a page response starts.
    private func nextDocument(_ id: Int?) -> RouterResponse {
        lock.lock()
        guard let id, let job = jobs.job(id) else { lock.unlock(); return notFound() }
        let streams = job.plan.streamsTIFF
        if job.nextDocumentServed {
            let streaming = streams && job.waiter.current == nil
            lock.unlock()
            return streaming ? retryLater() : notFound()
        }
        lock.unlock()
        if streams { return streamedDocument(job) }

        guard let result = job.waiter.wait(timeout: pageWait) else { return retryLater() }
        lock.lock(); defer { lock.unlock() }
        if job.nextDocumentServed { return notFound() }
        switch result {
        case .file(let url, let type):
            job.nextDocumentServed = true
            return RouterResponse(status: 200, body: .file(url, contentType: type))
        case .noMorePages: return notFound()
        case .failed: return RouterResponse(status: 500)
        }
    }

    private func streamedDocument(_ job: ScanJobRecord) -> RouterResponse {
        let geometry: PageGeometry
        switch job.waiter.waitForGeometry(timeout: pageWait) {
        case .ready(let g): geometry = g
        case .ended(.noMorePages): return notFound()
        case .ended: return RouterResponse(status: 500)
        case .timedOut: return retryLater()
        }
        let channels = job.plan.request.colorSpace == "Color" ? 3 : 1
        guard geometry.width > 0, geometry.height > 0, geometry.bytesPerLine >= geometry.width * channels else {
            return RouterResponse(status: 500)
        }
        lock.lock(); defer { lock.unlock() }
        if job.nextDocumentServed { return job.waiter.current == nil ? retryLater() : notFound() }
        job.nextDocumentServed = true
        let layout = TIFFLayout(geometry: geometry, channels: channels, dpi: job.resolution, threshold: job.plan.post.threshold)
        return RouterResponse(status: 200, body: .stream(PageStream(file: pageFile(job), layout: layout,
                                                                   contentType: job.plan.output.rawValue, waiter: job.waiter)))
    }

    private func retryLater() -> RouterResponse { RouterResponse(status: 503, headers: ["Retry-After": "2"]) }

    private func deleteJob(_ id: Int?) -> RouterResponse {
        lock.lock(); defer { lock.unlock() }
        guard let id, let job = jobs.job(id) else { return notFound() }
        if job.state == .processing {
            job.cancelled = true
            job.state = .canceled
        }
        return RouterResponse(status: 200)
    }
}
