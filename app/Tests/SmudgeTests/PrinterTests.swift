// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import XCTest
@testable import SmudgeCore
@testable import SmudgeKit

final class DeviceURITests: XCTestCase {
    func testSerialFromURI() {
        XCTAssertEqual(DeviceURI.serial("usb://HP/DeskJet%202300%20series?serial=CN171232SB"), "CN171232SB")
        XCTAssertEqual(USBCheck.serial(fromURI: "usb://HP/DeskJet%202300%20series?serial=CN171232SB"), "CN171232SB")
    }

    func testNoSerial() {
        XCTAssertNil(DeviceURI.serial("usb://HP/DeskJet%202300%20series"))
        XCTAssertNil(DeviceURI.serial("usb://HP/DeskJet%202300%20series?serial="))
        XCTAssertNil(DeviceURI.serial("ipp://printer.local/ipp/print?serial=ABC"))
    }

    func testSerialWithOtherQueryItems() {
        XCTAssertEqual(DeviceURI.serial("usb://HP/ENVY%206000%20series?interface=1&serial=TH1234"), "TH1234")
    }

    func testModelIsDecoded() {
        XCTAssertEqual(DeviceURI.model("usb://HP/DeskJet%202300%20series?serial=X"), "DeskJet 2300 series")
        XCTAssertEqual(DeviceURI.model("usb://HP/ENVY%205000%20series"), "ENVY 5000 series")
        XCTAssertNil(DeviceURI.model("ipp://host/ipp"))
    }

    func testIsUSB() {
        XCTAssertTrue(DeviceURI.isUSB("usb://HP/x"))
        XCTAssertFalse(DeviceURI.isUSB("ipp://x"))
        XCTAssertFalse(DeviceURI.isUSB(""))
    }
}

final class USBMatchTests: XCTestCase {
    private func iface(_ n: Int, _ c: Int = 255, _ s: Int = 4, _ p: Int = 1) -> USBInterfaceInfo {
        USBInterfaceInfo(number: n, interfaceClass: c, subclass: s, protocolCode: p)
    }
    private func device(_ pid: Int, _ serial: String?, vendor: Int = 0x03f0, _ ifaces: [USBInterfaceInfo]) -> USBDeviceInfo {
        USBDeviceInfo(vendor: vendor, product: pid, serial: serial, interfaces: ifaces, registryID: UInt64(pid))
    }

    func testInterfaceDiscoveryByClassSubclassProtocol() {
        let d = device(0x1111, "A", [iface(0, 7, 1, 2), iface(1, 255, 255, 255), iface(2), iface(3)])
        XCTAssertEqual(LEDMMatch.ledmInterface(of: d)?.number, 2)
    }

    func testInterfaceDiscoveryIgnoresProductID() {
        // An arbitrary PID still works, and the DeskJet 2300 PID without the interface does not.
        XCTAssertNotNil(LEDMMatch.ledmInterface(of: device(0xabcd, "A", [iface(1)])))
        XCTAssertNil(LEDMMatch.ledmInterface(of: device(0x3654, "A", [iface(0, 7, 1, 2)])))
    }

    func testNoLEDMInterface() {
        XCTAssertNil(LEDMMatch.ledmInterface(of: device(1, "A", [iface(0, 255, 4, 2), iface(1, 255, 3, 1), iface(2, 254, 4, 1)])))
    }

    func testPicksLowestLEDMInterface() {
        XCTAssertEqual(LEDMMatch.ledmInterface(of: device(1, "A", [iface(5), iface(2)]))?.number, 2)
    }

    func testChoosesDeviceBySerialAmongSeveral() {
        let devices = [
            device(0x3654, "AAA", [iface(1)]),
            device(0x5a1d, "BBB", [iface(2)]),
            device(0x0001, "CCC", vendor: 0x04b8, [iface(3)]),   // another vendor, same interface shape
        ]
        guard case .found(let d, let i) = LEDMMatch.lookup(serial: "BBB", in: devices) else { return XCTFail("not found") }
        XCTAssertEqual(d.product, 0x5a1d)
        XCTAssertEqual(i.number, 2)
        guard case .found(let d2, _) = LEDMMatch.lookup(serial: "AAA", in: devices) else { return XCTFail("not found") }
        XCTAssertEqual(d2.product, 0x3654)
    }

    func testOtherVendorsAreNeverMatched() {
        let devices = [device(1, "CCC", vendor: 0x04b8, [iface(0)])]
        XCTAssertEqual(LEDMMatch.lookup(serial: "CCC", in: devices), .notConnected)
    }

    func testUnknownSerialIsNotConnected() {
        let devices = [device(1, "AAA", [iface(0)]), device(2, "BBB", [iface(0)])]
        XCTAssertEqual(LEDMMatch.lookup(serial: "ZZZ", in: devices), .notConnected)
    }

    func testDeviceWithoutLEDMInterface() {
        let plain = device(7, "AAA", [iface(0, 7, 1, 2)])
        XCTAssertEqual(LEDMMatch.lookup(serial: "AAA", in: [plain]), .noLEDM(plain))
    }

    func testMissingSerialOnlyMatchesALoneHPDevice() {
        let one = [device(1, "AAA", [iface(0)])]
        guard case .found = LEDMMatch.lookup(serial: nil, in: one) else { return XCTFail("lone device should match") }
        let two = one + [device(2, "BBB", [iface(0)])]
        XCTAssertEqual(LEDMMatch.lookup(serial: nil, in: two), .notConnected)
    }

    func testClientsAreCachedPerSerialAndClosed() {
        let reg = LEDMClients()
        let a = reg.client(for: "A"), b = reg.client(for: "B")
        XCTAssertTrue(a === reg.client(for: "A"))
        XCTAssertFalse(a === b)
        XCTAssertEqual(a.serial, "A")
        reg.keepOnly("B")
        XCTAssertEqual(reg.count, 1)
        XCTAssertTrue(b === reg.client(for: "B"))
        reg.drop("B")
        XCTAssertEqual(reg.count, 0)
    }
}

final class InkLabelTests: XCTestCase {
    private func parse(_ items: [String]) throws -> InkReport {
        try XCTUnwrap(InkParser.parse(Fixture.data(Fixture.consumableConfig(items))))
    }

    func testOneCartridge() throws {
        let r = try parse([Fixture.ink(label: "K", percent: 70)])
        XCTAssertEqual(r.cartridges.count, 1)
        XCTAssertEqual(r.cartridges[0].name, "Black")
        XCTAssertEqual(r.cartridges[0].bands, [.black])
        XCTAssertTrue(r.cartridges[0].isBlack)
    }

    func testTwoCartridges() throws {
        let r = try parse([Fixture.ink(label: "CMY", percent: 90), Fixture.ink(label: "K", percent: 100)])
        XCTAssertEqual(r.cartridges.map(\.name), ["Tri-color", "Black"])
        XCTAssertEqual(r.cartridges[0].bands, [.cyan, .magenta, .yellow])
        XCTAssertTrue(r.cartridges[0].isMulti)
    }

    func testFourCartridges() throws {
        let r = try parse(["K", "C", "M", "Y"].enumerated().map { Fixture.ink(label: $1, percent: 10 * ($0 + 1)) })
        XCTAssertEqual(r.cartridges.map(\.label), ["K", "C", "M", "Y"])
        XCTAssertEqual(r.cartridges.map(\.name), ["Black", "Cyan", "Magenta", "Yellow"])
        XCTAssertEqual(r.cartridges.map(\.percent), [10, 20, 30, 40])
        XCTAssertEqual(r.cartridges.map(\.isMulti), [false, false, false, false])
    }

    func testFourColorCartridge() {
        XCTAssertEqual(InkLabel.bands("CMYK"), [.cyan, .magenta, .yellow, .black])
        XCTAssertEqual(InkLabel.name("CMYK"), "Four-color")
    }

    func testPhotoAndLightLabels() {
        XCTAssertEqual(InkLabel.bands("PK"), [.photo])
        XCTAssertEqual(InkLabel.name("LC"), "Light cyan")
        XCTAssertEqual(InkLabel.name("LM"), "Light magenta")
        XCTAssertEqual(InkLabel.name("GY"), "Gray")
    }

    func testUnknownLabelKeepsItsCode() throws {
        let r = try parse([Fixture.ink(label: "ZX9", percent: 55)])
        XCTAssertEqual(r.cartridges[0].name, "ZX9")
        XCTAssertEqual(r.cartridges[0].bands, [.other])
        XCTAssertEqual(r.cartridges[0].percent, 55)
        XCTAssertFalse(r.cartridges[0].isBlack)
    }

    func testLabelCaseIsIgnored() {
        XCTAssertEqual(InkLabel.bands("cmy"), [.cyan, .magenta, .yellow])
        XCTAssertEqual(InkLabel.name("k"), "Black")
    }
}

final class CapabilityTests: XCTestCase {
    private func caps(_ jobTypes: [String], _ alignment: String?) -> PrinterCaps {
        PrinterCaps(jobTypes: jobTypes, alignment: AlignmentSupport(mode: alignment))
    }

    func testParseFromFixtures() {
        let c = PrinterCaps.parse(printCap: Fixture.data(Fixture.internalPrintCap),
                                  consumables: Fixture.data(Fixture.consumablesTwoCartridges))
        XCTAssertEqual(c.alignment, .semiAutomatic)
        XCTAssertTrue(c.jobTypes.contains("cleaningPage"))
        XCTAssertEqual(c.cards, [.clean, .deepClean, .diagnostics, .align])
    }

    func testAutomaticAlignmentShowsTheCard() {
        XCTAssertEqual(caps(["cleaningPage"], "automatic").cards, [.clean, .align])
    }

    func testManualAlignmentHasNoCardAndSaysSo() {
        let c = caps(["cleaningPage", "diagnosticsPage"], "manual")
        XCTAssertEqual(c.cards, [.clean, .diagnostics])
        XCTAssertNotNil(c.alignmentNote)
        XCTAssertNil(caps([], "semiAutomatic").alignmentNote)
    }

    func testNoAlignmentModeHidesTheAlignmentCard() {
        XCTAssertEqual(caps(["cleaningPage", "cleaningPageLevel2"], nil).cards, [.clean, .deepClean])
    }

    func testMissingConsumablesMeansNoAlignment() {
        let c = PrinterCaps.parse(printCap: Fixture.data(Fixture.internalPrintCap), consumables: nil)
        XCTAssertEqual(c.alignment, .none)
        XCTAssertFalse(c.cards.contains(.align))
    }

    func testNothingSupported() {
        XCTAssertEqual(caps([], nil).cards, [])
    }
}

final class SelectionTests: XCTestCase {
    private func q(_ name: String, _ model: String, _ uri: String = "usb://HP/x") -> PrinterInfo {
        PrinterInfo(name: name, makeAndModel: model, deviceURI: uri)
    }

    func testShowsQueuesEndingInOurMarker() {
        let all = [q("A", "HP DeskJet 2300 series, Smudge"), q("B", "HP DeskJet 2300 series, Smudge"),
                   q("C", "HP OfficeJet 3830, 2.8.1"), q("D", "Generic PostScript")]
        XCTAssertEqual(PrinterChoice.shown(all).map(\.name), ["A", "B"])
    }

    func testMarkerMustBeAtTheEnd() {
        let all = [q("A", "smudge test queue"), q("B", "HP Envy 6000, Smudge")]
        XCTAssertEqual(PrinterChoice.shown(all).map(\.name), ["B"])
    }

    func testFallsBackToHPQueues() {
        let all = [q("A", "HP OfficeJet 3830"), q("B", "Brother HL-L2350DW", "ipp://b"), q("C", "", "usb://HP/Envy")]
        XCTAssertEqual(PrinterChoice.shown(all).map(\.name), ["A", "C"])
    }

    func testFallsBackToEveryQueue() {
        let all = [q("A", "Brother HL", "ipp://a"), q("B", "Canon MG", "ipp://b")]
        XCTAssertEqual(PrinterChoice.shown(all).map(\.name), ["A", "B"])
        XCTAssertEqual(PrinterChoice.shown([]).count, 0)
    }

    func testKeepsTheRememberedQueue() {
        let list = [q("A", ""), q("B", "")]
        XCTAssertEqual(PrinterChoice.resolve(current: "B", in: list), "B")
    }

    func testFirstQueueWhenNothingRememberedOrQueueIsGone() {
        let list = [q("A", ""), q("B", "")]
        XCTAssertEqual(PrinterChoice.resolve(current: "", in: list), "A")
        XCTAssertEqual(PrinterChoice.resolve(current: "HP_DeskJet_2300", in: list), "A")
        XCTAssertNil(PrinterChoice.resolve(current: "A", in: []))
    }

    func testConnectionState() {
        let usb = q("A", "", "usb://HP/DeskJet%202300%20series?serial=S1")
        XCTAssertEqual(PrinterChoice.connection(of: usb, connected: ["S1", "S2"]), true)
        XCTAssertEqual(PrinterChoice.connection(of: usb, connected: ["S2"]), false)
        XCTAssertNil(PrinterChoice.connection(of: q("B", "", "usb://HP/x"), connected: ["S1"]))
        XCTAssertNil(PrinterChoice.connection(of: q("C", "", "ipp://x/y"), connected: ["S1"]))
    }

    func testModelNameDropsTheDriverMarker() {
        XCTAssertEqual(StatusStore.model(of: q("A", "HP DeskJet 2300 series, Smudge")), "HP DeskJet 2300 series")
        XCTAssertEqual(StatusStore.model(of: q("B", "", "usb://HP/ENVY%206000%20series?serial=Z")), "ENVY 6000 series")
    }
}

final class ScanChannelTests: XCTestCase {
    func testScanChannelMatchesCC0Only() {
        let dev = USBDeviceInfo(vendor: 0x03f0, product: 0x3654, serial: "CN171232SB", interfaces: [
            USBInterfaceInfo(number: 0, interfaceClass: 255, subclass: 0xcc, protocolCode: 0),
            USBInterfaceInfo(number: 1, interfaceClass: 7, subclass: 1, protocolCode: 2),
            USBInterfaceInfo(number: 2, interfaceClass: 255, subclass: 4, protocolCode: 1),
            USBInterfaceInfo(number: 3, interfaceClass: 255, subclass: 4, protocolCode: 1),
        ], registryID: 1)
        XCTAssertEqual(LEDMMatch.interface(of: dev, channel: .scan)?.number, 0)
        XCTAssertEqual(LEDMMatch.interface(of: dev, channel: .management)?.number, 2)
        XCTAssertEqual(LEDMMatch.lookup(serial: "CN171232SB", in: [dev], channel: .scan), .found(dev, dev.interfaces[0]))
    }
}

@MainActor
final class ScannerStateTests: XCTestCase {
    private func store() -> StatusStore {
        let s = StatusStore()
        s.status = PrinterStatus(name: "P", stateCode: 3, message: "", reasons: [], deviceURI: "usb://HP/X?serial=A",
                                 makeAndModel: "HP X", ink: [], error: nil)
        s.usbPresent = true
        return s
    }

    func testResolve() {
        XCTAssertEqual(ScannerState.resolve(hasInterface: false, sharing: true, activity: nil), .none)
        XCTAssertEqual(ScannerState.resolve(hasInterface: false, sharing: true, activity: .scanning), .none)
        XCTAssertEqual(ScannerState.resolve(hasInterface: true, sharing: false, activity: nil), .off)
        XCTAssertEqual(ScannerState.resolve(hasInterface: true, sharing: true, activity: nil), .ready)
        XCTAssertEqual(ScannerState.resolve(hasInterface: true, sharing: true, activity: .maintenance), .ready)
        XCTAssertEqual(ScannerState.resolve(hasInterface: true, sharing: true, activity: .scanning), .scanning)
    }

    func testHealthScanningOutranksPrintingButNotAttention() {
        let s = store()
        s.jobs = [PrintJob(id: 1, title: "t", user: "u", sizeKB: 1, stateCode: 5, time: Date(), reasons: [])]
        XCTAssertEqual(s.health, .printing)
        s.scanner = .scanning
        XCTAssertEqual(s.health, .scanning)
        XCTAssertEqual(s.healthTitle, "Scanning")
        s.status?.stateCode = 5          // stopped needs attention
        XCTAssertEqual(s.health, .attention)
    }

    func testMaintenanceBlockedWhileScanning() {
        let s = store()
        XCTAssertNil(s.maintenanceBlockReason)
        s.scanner = .scanning
        XCTAssertEqual(s.maintenanceBlockReason, "The scanner is in use. Wait for the scan to finish.")
    }

    func testJobCardDoesNotCallAScanPrinting() {
        let s = store()
        XCTAssertEqual(s.idleJobText, "Nothing is printing.")
        s.ledmCategories = ["processing"]
        XCTAssertEqual(s.idleJobText, "The printer is working.")
        s.scanner = .scanning
        XCTAssertEqual(s.idleJobText, "Nothing is printing.")
    }

    func testScanChannelFromUSBDevices() {
        let dev = USBDeviceInfo(vendor: 0x03f0, product: 0x3654, serial: "A", interfaces: [
            USBInterfaceInfo(number: 0, interfaceClass: 255, subclass: 0xcc, protocolCode: 0),
            USBInterfaceInfo(number: 2, interfaceClass: 255, subclass: 4, protocolCode: 1)], registryID: 1)
        XCTAssertTrue(ScannerState.hasScanInterface(serial: "A", in: [dev]))
        XCTAssertFalse(ScannerState.hasScanInterface(serial: "B", in: [dev]))
        XCTAssertFalse(ScannerState.hasScanInterface(serial: nil, in: [dev, dev]))
    }
}
