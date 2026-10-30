// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

/// How the scanner's ToneMap Brightness and Contrast values relate to eSCL's 0...2000 scale.
public struct ToneCalibration: Sendable {
    /// The device value that leaves the image unchanged.
    public var neutral: Int
    public var min: Int
    public var max: Int
    /// False when the device ignores the fields, so the agent adjusts the image itself.
    public var deviceApplies: Bool

    public init(neutral: Int, min: Int, max: Int, deviceApplies: Bool) {
        self.neutral = neutral
        self.min = min
        self.max = max
        self.deviceApplies = deviceApplies
    }

    public static let deskJet2300 = ToneCalibration(neutral: 1000, min: 0, max: 2000, deviceApplies: true)

    /// eSCL 1000, or nil, maps to `neutral`. 0 maps to `min` and 2000 to `max`, linear on each side.
    public func device(_ escl: Int?) -> Int {
        guard let escl else { return neutral }
        let v = Swift.min(Swift.max(escl, 0), 2000)
        if v <= 1000 { return min + (neutral - min) * v / 1000 }
        return neutral + (max - neutral) * (v - 1000) / 1000
    }
}
