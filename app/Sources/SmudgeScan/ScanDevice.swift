// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

public enum ScanOutcome: Equatable, Sendable {
    case page(bytes: Int)
    case noDocument
    case canceledByDevice
    case canceledByClient
}

/// The scanner as the router sees it.
public protocol ScanDevice: AnyObject, Sendable {
    var caps: LEDMScanCaps { get }
    /// The LEDM ScannerState, "Idle" when ready. Throws when the scanner cannot be reached.
    func scannerState() throws -> String
    /// Runs one job and writes the page to `file`. `isCancelled` is polled while the job runs.
    /// `onPageReady` gets the page size when the printer has the page ready, before the download starts.
    func scan(_ request: LEDMScanRequest, to file: URL, isCancelled: @escaping @Sendable () -> Bool,
              onPageReady: @escaping @Sendable (PageGeometry) -> Void) throws -> ScanOutcome
}
