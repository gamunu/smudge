// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import SystemConfiguration

/// Tells whether this process's user owns the console, the session in front of the screen. With
/// fast user switching every logged-in user runs an agent, and only the console user's one serves.
final class ConsoleGate {
    private let onChange: (Bool) -> Void
    private var store: SCDynamicStore?
    private let queue = DispatchQueue(label: "scand.console")

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        var ctx = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "smudge-scand" as CFString, { _, _, info in
            guard let info else { return }
            let me = Unmanaged<ConsoleGate>.fromOpaque(info).takeUnretainedValue()
            me.onChange(me.isConsoleUser)
        }, &ctx) else { return }
        self.store = store
        let key = SCDynamicStoreKeyCreateConsoleUser(nil)
        SCDynamicStoreSetNotificationKeys(store, [key] as CFArray, nil)
        SCDynamicStoreSetDispatchQueue(store, queue)
    }

    var isConsoleUser: Bool {
        var uid: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(store, &uid, nil) != nil else { return false }
        return uid == getuid()
    }
}
