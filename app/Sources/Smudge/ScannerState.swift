// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import SmudgeKit

/// What the Smudge window shows for the printer's scanner.
enum ScannerState: Equatable, Sendable {
    /// The printer has no scan interface.
    case none
    case ready
    case scanning
    /// Scanner sharing is turned off in Settings.
    case off

    static let sharingKey = "scanSharing"
    static let sharingChanged = Notification.Name("io.github.gamunu.smudge.scanSharingChanged")

    /// Scanner sharing, on unless the user turned it off.
    static var sharingEnabled: Bool {
        UserDefaults.standard.object(forKey: sharingKey) as? Bool ?? true
    }

    static func resolve(hasInterface: Bool, sharing: Bool, activity: PrinterActivity?) -> ScannerState {
        guard hasInterface else { return .none }
        guard sharing else { return .off }
        return activity == .scanning ? .scanning : .ready
    }

    /// True when the HP device with this serial has a scan interface (255/0xcc/0).
    static func hasScanInterface(serial: String?, in devices: [USBDeviceInfo]) -> Bool {
        if case .found = LEDMMatch.lookup(serial: serial, in: devices, channel: .scan) { return true }
        return false
    }
}
