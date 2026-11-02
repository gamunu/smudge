// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import IOKit
import SmudgeKit

/// Reports HP devices with a scan interface (255/0xcc/0) as they arrive and leave. It does not poll.
/// IOKit tells it when an interface appears or goes away. Arrivals are found by comparing the attached
/// devices with the ones already reported. Removals are taken from the terminated interface itself,
/// because a scan that still holds the interface open keeps it listed in the registry for a while.
final class DeviceWatcher {
    private let onAdd: (USBDeviceInfo) -> Void
    private let onRemove: (UInt64) -> Void
    private let queue = DispatchQueue(label: "scand.watcher")
    private var port: IONotificationPortRef?
    private var known: [UInt64: USBDeviceInfo] = [:]
    /// Registry id of each reported device's scan interface, mapped to the device's registry id.
    private var interfaces: [UInt64: UInt64] = [:]

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
        let terminated = type == kIOTerminatedNotification
        let callback: IOServiceMatchingCallback = terminated ? { refcon, iterator in
            // Draining the iterator re-arms the notification.
            var gone: [UInt64] = []
            while case let s = IOIteratorNext(iterator), s != 0 {
                var id: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(s, &id) == KERN_SUCCESS { gone.append(id) }
                IOObjectRelease(s)
            }
            guard let refcon else { return }
            Unmanaged<DeviceWatcher>.fromOpaque(refcon).takeUnretainedValue().interfacesGone(gone)
        } : { refcon, iterator in
            while case let s = IOIteratorNext(iterator), s != 0 { IOObjectRelease(s) }
            guard let refcon else { return }
            Unmanaged<DeviceWatcher>.fromOpaque(refcon).takeUnretainedValue().reconcile()
        }
        let kr = IOServiceAddMatchingNotification(port, type, match, callback, ctx, &iter)
        guard kr == KERN_SUCCESS else { return }
        while case let s = IOIteratorNext(iter), s != 0 { IOObjectRelease(s) }
        reconcile()
    }

    private func reconcile() {
        let scan = USBScan.scan()
        defer { for (_, m) in scan.services { for (_, s) in m { IOObjectRelease(s) } } }
        let now = scan.devices.filter { d in
            d.vendor == LEDMMatch.hpVendor && LEDMMatch.interface(of: d, channel: .scan) != nil
        }
        for d in now where known[d.registryID] == nil {
            guard let iface = LEDMMatch.interface(of: d, channel: .scan),
                  let svc = scan.services[d.registryID]?[iface.number] else { continue }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(svc, &id) == KERN_SUCCESS else { continue }
            known[d.registryID] = d
            interfaces[id] = d.registryID
            onAdd(d)
        }
    }

    private func interfacesGone(_ ids: [UInt64]) {
        for id in ids {
            guard let device = interfaces.removeValue(forKey: id), known.removeValue(forKey: device) != nil else { continue }
            onRemove(device)
        }
    }
}
