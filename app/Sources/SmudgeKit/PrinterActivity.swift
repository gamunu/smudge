// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

/// What a process is doing with a printer, so the app and the scanner agent stay out of each other's way.
public enum PrinterActivity: String, Codable, Sendable {
    case scanning, maintenance
}

/// One small file per writer and printer serial. The agent writes "scanning", the app writes
/// "maintenance". An entry whose pid is gone counts as nothing.
public struct ActivityStore {
    public enum Writer: String, Sendable { case app, scand }

    private struct Entry: Codable {
        var activity: PrinterActivity
        var since: Date
        var pid: Int32
    }

    public let directory: URL

    public static let defaultDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Smudge/activity", isDirectory: true)
    }()

    public init(directory: URL = ActivityStore.defaultDirectory) { self.directory = directory }

    public static func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    private func file(_ serial: String, _ writer: Writer) -> URL {
        let safe = serial.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent("\(safe).\(writer.rawValue).json")
    }

    /// Records what this process is doing, or clears the entry with nil.
    public func set(_ a: PrinterActivity?, serial: String, writer: Writer) {
        let url = file(serial, writer)
        guard let a else { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(Entry(activity: a, since: Date(), pid: getpid())) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public func current(serial: String, from writer: Writer, pidAlive: (Int32) -> Bool = ActivityStore.isAlive) -> PrinterActivity? {
        guard let data = try? Data(contentsOf: file(serial, writer)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let e = try? dec.decode(Entry.self, from: data), pidAlive(e.pid) else { return nil }
        return e.activity
    }
}
