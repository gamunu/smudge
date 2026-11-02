// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import IOKit
import SmudgeKit

/// Reports HP devices with a scan interface (255/0xcc/0) as they arrive and leave. It does not poll.
/// Arrivals come from interface notifications: the scan interface is picked out by its properties in
/// the callback, because a matching request filtered on interface class never fires. Removals come
/// from the USB device itself terminating. Interfaces alone are not enough there: the system tears
/// them down and recreates them while the printer stays attached.
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
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        var arrived: io_iterator_t = 0
        if IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostInterface"), { refcon, iterator in
            // Draining the iterator re-arms the notification.
            var scan = false
            while case let s = IOIteratorNext(iterator), s != 0 {
                if DeviceWatcher.isScanInterface(s) { scan = true }
                IOObjectRelease(s)
            }
            guard scan, let refcon else { return }
            Unmanaged<DeviceWatcher>.fromOpaque(refcon).takeUnretainedValue().reconcile()
        }, ctx, &arrived) == KERN_SUCCESS {
            while case let s = IOIteratorNext(arrived), s != 0 { IOObjectRelease(s) }
        }
        var gone: io_iterator_t = 0
        if IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"), { refcon, iterator in
            var ids: [UInt64] = []
            while case let s = IOIteratorNext(iterator), s != 0 {
                var id: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(s, &id) == KERN_SUCCESS { ids.append(id) }
                IOObjectRelease(s)
            }
            guard let refcon else { return }
            Unmanaged<DeviceWatcher>.fromOpaque(refcon).takeUnretainedValue().devicesGone(ids)
        }, ctx, &gone) == KERN_SUCCESS {
            while case let s = IOIteratorNext(gone), s != 0 { IOObjectRelease(s) }
        }
        queue.async { self.reconcile() }
    }

    static func isScanInterface(_ s: io_service_t) -> Bool {
        func int(_ k: String) -> Int? { USBScan.prop(k, of: s) as? Int }
        return int("bInterfaceClass") == 255 && int("bInterfaceSubClass") == 0xcc && int("bInterfaceProtocol") == 0
    }

    private func reconcile() {
        let now = USBScan.devices().filter { d in
            d.vendor == LEDMMatch.hpVendor && LEDMMatch.interface(of: d, channel: .scan) != nil
        }
        for d in now where known[d.registryID] == nil {
            known[d.registryID] = d
            onAdd(d)
        }
    }

    private func devicesGone(_ ids: [UInt64]) {
        for id in ids where known.removeValue(forKey: id) != nil {
            onRemove(id)
        }
    }
}
