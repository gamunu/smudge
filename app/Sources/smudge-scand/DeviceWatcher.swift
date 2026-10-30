// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import IOKit
import SmudgeKit

/// Reports HP devices with a scan interface (255/0xcc/0) as they arrive and leave. It does not poll.
/// IOKit tells it when an interface appears or goes away, and it then compares the attached devices
/// with the ones it has already reported.
final class DeviceWatcher {
    private let onAdd: (USBDeviceInfo) -> Void
    private let onRemove: (UInt64) -> Void
    private let queue = DispatchQueue(label: "scand.watcher")
    private var port: IONotificationPortRef?
    private var known: [UInt64: USBDeviceInfo] = [:]

    init(onAdd: @escaping (USBDeviceInfo) -> Void, onRemove: @escaping (UInt64) -> Void) {
        self.onAdd = onAdd
        self.onRemove = onRemove
    }

    /// Devices already attached are reported once, right away.
    func start() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, queue)
        arm(port, kIOFirstMatchNotification)
        arm(port, kIOTerminatedNotification)
    }

    private func arm(_ port: IONotificationPortRef, _ type: String) {
        let match = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
        match["bInterfaceClass"] = 255
        match["bInterfaceSubClass"] = 204
        match["bInterfaceProtocol"] = 0
        var iter: io_iterator_t = 0
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let kr = IOServiceAddMatchingNotification(port, type, match, { refcon, iterator in
            // Draining the iterator re-arms the notification.
            while case let s = IOIteratorNext(iterator), s != 0 { IOObjectRelease(s) }
            guard let refcon else { return }
            let me = Unmanaged<DeviceWatcher>.fromOpaque(refcon).takeUnretainedValue()
            me.reconcile()
            // A terminated interface can still be listed for a moment.
            me.queue.asyncAfter(deadline: .now() + 0.3) { me.reconcile() }
            me.queue.asyncAfter(deadline: .now() + 1.5) { me.reconcile() }
        }, ctx, &iter)
        guard kr == KERN_SUCCESS else { return }
        while case let s = IOIteratorNext(iter), s != 0 { IOObjectRelease(s) }
        reconcile()
    }

    private func reconcile() {
        let now = USBScan.devices().filter { d in
            d.vendor == LEDMMatch.hpVendor && LEDMMatch.interface(of: d, channel: .scan) != nil
        }
        let ids = Set(now.map(\.registryID))
        for id in known.keys where !ids.contains(id) {
            known[id] = nil
            onRemove(id)
        }
        for d in now where known[d.registryID] == nil {
            known[d.registryID] = d
            onAdd(d)
        }
    }
}
