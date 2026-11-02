// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
@testable import SmudgeKit

/// In-memory stand-in for the USB pipe. Bytes the printer "sends" are queued by `onWrite`, so
/// `drain` only sees what was queued before the request, like stale replies on the real device.
final class FakeTransport: LEDMTransport {
    enum Step { case data(Data), fail(Error) }

    var stale: [Data] = []
    /// Called with each request written; returns the steps to queue as the printer's answer.
    var onWrite: (Data) -> [Step] = { _ in [] }
    /// Returned forever once the queue is empty, to model a device that never stops talking.
    var endless: Data?
    private(set) var written: [Data] = []
    private(set) var drained = 0
    private(set) var reads = 0
    private var queue: [Step] = []
    var failWrite: Error?

    init(replies: [Step] = []) { onWrite = { _ in replies } }

    convenience init(reply: Data, chunk: Int? = nil) {
        self.init(replies: Self.split(reply, chunk))
    }

    static func split(_ d: Data, _ chunk: Int?) -> [Step] {
        guard let chunk else { return [.data(d)] }
        return stride(from: 0, to: d.count, by: chunk).map { .data(d.subdata(in: $0..<min($0 + chunk, d.count))) }
    }

    func write(_ data: Data, timeout: TimeInterval) throws {
        if let failWrite { throw failWrite }
        written.append(data)
        queue += onWrite(data)
    }

    func read(timeout: TimeInterval) throws -> Data {
        reads += 1
        if !queue.isEmpty {
            switch queue.removeFirst() {
            case .data(let d): return d
            case .fail(let e): throw e
            }
        }
        if let endless { return endless }
        Thread.sleep(forTimeInterval: 0.001)   // an idle read on USB blocks until its timeout
        return Data()
    }

    func drain(quiet: TimeInterval) {
        drained += 1
        stale.removeAll()
    }
}
