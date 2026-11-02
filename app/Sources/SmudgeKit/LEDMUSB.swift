// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import IOKit
import IOUSBHost

public enum LEDMError: Error, LocalizedError {
    case deviceNotFound
    case open(String)
    case io(String)
    case timeout
    case noLEDM
    case badReply(String)
    case http(Int, String)
    case canceled

    public static let noInterfaceReason = "This printer does not report ink levels over USB"

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound: return "Printer USB interface not found"
        case .open(let m): return "Cannot open printer USB interface: \(m)"
        case .io(let m): return "USB transfer failed: \(m)"
        case .noLEDM: return Self.noInterfaceReason
        case .timeout: return "Printer did not answer in time"
        case .badReply(let m): return "Unexpected printer reply: \(m)"
        case .http(let c, let m): return "Printer returned HTTP \(c) \(m)"
        case .canceled: return "Canceled"
        }
    }
}

/// One claimed LEDM interface (management 255/4/1, or scan 255/0xcc/0).
/// Uses IOUSBHost, so there is no libusb dependency. Not thread safe on its
/// own: LEDMClient serializes access.
public final class LEDMUSBConnection {
    private let interface: IOUSBHostInterface
    private let outPipe: IOUSBHostPipe
    private let inPipe: IOUSBHostPipe
    private let maxPacket: Int

    /// Opens the LEDM interface of the HP device with this serial. Without a serial, the
    /// only attached HP device is used. Throws `.noLEDM` when the device has no such interface.
    public init(serial: String?, channel: LEDMChannel = .management) throws {
        let scan = USBScan.scan()
        var keep: io_service_t = 0
        defer {
            for (_, byNumber) in scan.services { for (_, svc) in byNumber where svc != keep { IOObjectRelease(svc) } }
        }
        switch LEDMMatch.lookup(serial: serial, in: scan.devices, channel: channel) {
        case .notConnected: throw LEDMError.deviceNotFound
        case .noLEDM: throw LEDMError.noLEDM
        case .found(let dev, let iface):
            guard let svc = scan.services[dev.registryID]?[iface.number] else { throw LEDMError.deviceNotFound }
            keep = svc
        }
        defer { IOObjectRelease(keep) }
        let pick = (service: keep, number: 0)

        do {
            interface = try IOUSBHostInterface(__ioService: pick.service, options: [], queue: nil,
                                               interestHandler: nil)
        } catch {
            throw LEDMError.open(error.localizedDescription)
        }

        // Walk the endpoint descriptors for the bulk pair.
        var outAddr = 0, inAddr = 0, mps = 512
        let ifDesc = interface.interfaceDescriptor
        let cfgDesc = interface.configurationDescriptor
        var ep = IOUSBGetNextEndpointDescriptor(cfgDesc, ifDesc, nil)
        while let d = ep {
            let addr = Int(d.pointee.bEndpointAddress)
            if d.pointee.bmAttributes & 3 == 2 {
                if addr & 0x80 != 0 { if inAddr == 0 { inAddr = addr; mps = Int(d.pointee.wMaxPacketSize) } }
                else if outAddr == 0 { outAddr = addr }
            }
            ep = IOUSBGetNextEndpointDescriptor(cfgDesc, ifDesc, UnsafeRawPointer(d).assumingMemoryBound(to: IOUSBDescriptorHeader.self))
        }
        guard outAddr != 0, inAddr != 0 else { interface.destroy(); throw LEDMError.open("no bulk endpoints") }
        do {
            outPipe = try interface.copyPipe(withAddress: outAddr)
            inPipe = try interface.copyPipe(withAddress: inAddr)
        } catch {
            interface.destroy()
            throw LEDMError.open(error.localizedDescription)
        }
        maxPacket = max(mps, 64)
    }

    deinit { interface.destroy() }

    public func write(_ data: Data, timeout: TimeInterval = 5) throws {
        var offset = 0
        while offset < data.count {
            let n = min(16384, data.count - offset)
            let buf = NSMutableData(data: data.subdata(in: offset..<offset + n))
            var sent = 0
            do {
                try outPipe.__sendIORequest(with: buf, bytesTransferred: &sent, completionTimeout: timeout)
            } catch {
                throw LEDMError.io(error.localizedDescription)
            }
            offset += max(sent, 0)
            if sent == 0 { break }
        }
    }

    /// Reads one bulk transfer. Returns empty Data on timeout.
    public func read(timeout: TimeInterval) throws -> Data {
        // The transfer buffer is autoreleased. A pool per read keeps a long download from holding them all.
        try autoreleasepool {
            let size = 16384
            let buf = NSMutableData(length: size)!
            var got = 0
            do {
                try inPipe.__sendIORequest(with: buf, bytesTransferred: &got, completionTimeout: timeout)
            } catch {
                let ns = error as NSError
                let code = UInt32(bitPattern: Int32(truncatingIfNeeded: ns.code))
                // kIOReturnTimeout, kIOReturnAborted, kIOUSBTransactionTimeout
                if code == 0xe00002d6 || code == 0xe00002eb || code == 0xe0004051 { return Data() }
                throw LEDMError.io("\(error.localizedDescription) (\(ns.code))")
            }
            return Data(bytes: buf.bytes, count: got)
        }
    }

    /// Throws away anything the printer still has queued from earlier requests.
    public func drain(quiet: TimeInterval) {
        while let d = try? read(timeout: quiet), !d.isEmpty {}
    }
}

/// Reads the USB registry into plain values, keeping the interface services so one can be opened.
public enum USBScan {
    public static func prop(_ k: String, of s: io_service_t) -> Any? {
        IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Every USB interface grouped by its device. The caller releases the services.
    public static func scan() -> (devices: [USBDeviceInfo], services: [UInt64: [Int: io_service_t]]) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOUSBHostInterface"), &iter) == KERN_SUCCESS
        else { return ([], [:]) }
        defer { IOObjectRelease(iter) }
        var devices: [UInt64: USBDeviceInfo] = [:]
        var services: [UInt64: [Int: io_service_t]] = [:]
        while case let e = IOIteratorNext(iter), e != 0 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(e, kIOServicePlane, &parent) == KERN_SUCCESS else {
                IOObjectRelease(e); continue
            }
            defer { IOObjectRelease(parent) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(parent, &id) == KERN_SUCCESS,
                  let vid = prop("idVendor", of: parent) as? Int,
                  let pid = prop("idProduct", of: parent) as? Int,
                  let num = prop("bInterfaceNumber", of: e) as? Int else { IOObjectRelease(e); continue }
            let iface = USBInterfaceInfo(number: num,
                                         interfaceClass: prop("bInterfaceClass", of: e) as? Int ?? -1,
                                         subclass: prop("bInterfaceSubClass", of: e) as? Int ?? -1,
                                         protocolCode: prop("bInterfaceProtocol", of: e) as? Int ?? -1)
            if devices[id] == nil {
                devices[id] = USBDeviceInfo(vendor: vid, product: pid,
                                            serial: prop("USB Serial Number", of: parent) as? String,
                                            interfaces: [], registryID: id)
            }
            devices[id]!.interfaces.append(iface)
            services[id, default: [:]][num] = e   // keeps the iterator's reference
        }
        return (devices.values.sorted { $0.registryID < $1.registryID }, services)
    }

    /// Plain snapshot of the attached USB devices.
    public static func devices() -> [USBDeviceInfo] {
        let r = scan()
        for (_, m) in r.services { for (_, s) in m { IOObjectRelease(s) } }
        return r.devices
    }
}
