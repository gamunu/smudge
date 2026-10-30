// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

// MARK: USB device model (pure, so it can be tested with fake devices)

public struct USBInterfaceInfo: Equatable, Sendable {
    public var number: Int
    public var interfaceClass: Int
    public var subclass: Int
    public var protocolCode: Int

    public init(number: Int, interfaceClass: Int, subclass: Int, protocolCode: Int) {
        self.number = number
        self.interfaceClass = interfaceClass
        self.subclass = subclass
        self.protocolCode = protocolCode
    }

    /// The LEDM channel: vendor class 255, subclass 4, protocol 1.
    public var isLEDM: Bool { interfaceClass == 255 && subclass == 4 && protocolCode == 1 }

    /// The LEDM scan channel: vendor class 255, subclass 0xcc, protocol 0.
    public var isLEDMScan: Bool { interfaceClass == 255 && subclass == 0xcc && protocolCode == 0 }
}

public struct USBDeviceInfo: Equatable, Sendable {
    public var vendor: Int
    public var product: Int
    public var serial: String?
    public var interfaces: [USBInterfaceInfo]
    public var registryID: UInt64 = 0

    public init(vendor: Int, product: Int, serial: String?, interfaces: [USBInterfaceInfo], registryID: UInt64 = 0) {
        self.vendor = vendor
        self.product = product
        self.serial = serial
        self.interfaces = interfaces
        self.registryID = registryID
    }
}

public enum LEDMLookup: Equatable, Sendable {
    case notConnected
    case noLEDM(USBDeviceInfo)
    case found(USBDeviceInfo, USBInterfaceInfo)
}

/// Which LEDM interface of a printer to talk to.
public enum LEDMChannel: Sendable {
    /// Ink, maintenance and device management (255/4/1).
    case management
    /// Scanning (255/0xcc/0).
    case scan

    public func matches(_ i: USBInterfaceInfo) -> Bool {
        switch self {
        case .management: return i.isLEDM
        case .scan: return i.isLEDMScan
        }
    }
}

public enum LEDMMatch {
    public static let hpVendor = 0x03f0

    /// The LEDM interface of a device, the lowest numbered one when there are several.
    public static func ledmInterface(of device: USBDeviceInfo) -> USBInterfaceInfo? {
        interface(of: device, channel: .management)
    }

    /// The interface of a device on one channel, the lowest numbered match.
    public static func interface(of device: USBDeviceInfo, channel: LEDMChannel) -> USBInterfaceInfo? {
        device.interfaces.filter { channel.matches($0) }.min { $0.number < $1.number }
    }

    /// Picks the HP device that belongs to a queue. With a serial, only that device matches. Without
    /// one, a lone HP device is taken, because with several there is no way to tell which is meant.
    public static func lookup(serial: String?, in devices: [USBDeviceInfo],
                              channel: LEDMChannel = .management) -> LEDMLookup {
        let hp = devices.filter { $0.vendor == hpVendor }
        let device: USBDeviceInfo?
        if let serial, !serial.isEmpty {
            device = hp.first { $0.serial == serial }
        } else {
            device = hp.count == 1 ? hp[0] : nil
        }
        guard let device else { return .notConnected }
        guard let iface = interface(of: device, channel: channel) else { return .noLEDM(device) }
        return .found(device, iface)
    }
}
