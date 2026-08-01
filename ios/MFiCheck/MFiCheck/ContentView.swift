// Copyright (C) 2026 miband contributors
//
// This file is part of miband.
//
// miband is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// miband is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// One-shot diagnostics for whether/how the Band 10 is reachable from a
// non-jailbroken iOS app:
//
// 1. EAAccessoryManager.connectedAccessories -- non-empty = MFi-registered,
//    RFCOMM/SPP reachable via ExternalAccessory. Empty is NOT conclusive by
//    itself: filtered by this app's declared protocol strings (none set).
// 2. CBCentralManager BLE scan -- no MFi gate, sees any advertising BLE
//    peripheral. Confirmed on real hardware: the Band 10 *does* advertise
//    over BLE (contradicts docs/PROTOCOL.md §0, which assumed classic-BT
//    only based on Gadgetbridge/Android source -- Android just never needed
//    the BLE side). The advertisement carries no service list, so tap the
//    row to connect and enumerate the real GATT table.

import SwiftUI
import ExternalAccessory
import CoreBluetooth
import UIKit

struct ContentView: View {
    @State private var mfiOutput = "Tap per controllare."
    @StateObject private var bleScanner = BLEScanner()
    @State private var onlyBand10 = true

    // Same pattern as DEVICE_NAME_RE in src/miband/transport.py.
    private static let band10Regex = try! NSRegularExpression(pattern: "^Xiaomi Smart Band 10 [0-9A-F]{4}$")

    private var visibleDevices: [BLEScanner.Found] {
        guard onlyBand10 else { return bleScanner.found }
        return bleScanner.found.filter { item in
            let range = NSRange(item.name.startIndex..., in: item.name)
            return Self.band10Regex.firstMatch(in: item.name, range: range) != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MFi (ExternalAccessory)").font(.headline)
            ScrollView {
                Text(mfiOutput)
                    .font(.system(.caption, design: .monospaced))
            }
            .frame(maxHeight: 100)
            HStack {
                Button("Check connected accessories") { checkMFi() }
                Button("Copy") { UIPasteboard.general.string = mfiOutput }
            }

            Divider()

            Text("BLE scan (CoreBluetooth) -- tap a device to connect + enumerate GATT")
                .font(.headline)
            Toggle("Solo Band 10 (\(bleScanner.found.count) totali)", isOn: $onlyBand10)
            List(visibleDevices) { item in
                Button {
                    bleScanner.connect(item)
                } label: {
                    Text("\(item.name)  rssi=\(item.rssi)  services=\(item.services)  mfg=\(item.mfgData)")
                        .font(.system(.caption, design: .monospaced))
                }
            }
            .frame(maxHeight: 150)
            Button(bleScanner.isScanning ? "Stop scan" : "Start BLE scan") {
                bleScanner.toggle()
            }

            Divider()

            Text("GATT").font(.headline)
            ScrollView {
                Text(bleScanner.gattOutput)
                    .font(.system(.caption, design: .monospaced))
            }
            HStack {
                Button("Probe FDAB (blind bytes)") { bleScanner.probeFDAB() }
                Button("Probe FDAB (SPP-V1 Version read)") { bleScanner.probeSppV1VersionRead() }
                Button("Copy") { UIPasteboard.general.string = bleScanner.gattOutput }
            }
        }
        .padding()
        .onAppear(perform: checkMFi)
    }

    func checkMFi() {
        let accessories = EAAccessoryManager.shared().connectedAccessories
        if accessories.isEmpty {
            mfiOutput = "connectedAccessories: EMPTY\n(0 accessori visibili come MFi)"
            return
        }
        mfiOutput = accessories.map { acc in
            """
            name: \(acc.name)
            manufacturer: \(acc.manufacturer)
            modelNumber: \(acc.modelNumber)
            protocolStrings: \(acc.protocolStrings)
            connectionID: \(acc.connectionID)
            """
        }.joined(separator: "\n---\n")
    }
}

final class BLEScanner: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct Found: Identifiable {
        let id: UUID
        var name: String
        var rssi: Int
        var services: String
        var mfgData: String
    }

    @Published var found: [Found] = []
    @Published var isScanning = false
    @Published var gattOutput = "Seleziona un dispositivo per connetterti."

    private var manager: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var connectedPeripheral: CBPeripheral?

    // Vendor-custom service, unverified payload -- see docs/PROTOCOL.md §0a.
    private static let fdabService = CBUUID(string: "FDAB")
    private static let fdabChar0001 = CBUUID(string: "0001")
    private static let fdabChar0002 = CBUUID(string: "0002")
    private static let fdabChar0003 = CBUUID(string: "0003")
    private var fdabChar0002Ref: CBCharacteristic?
    private var fdabChar0003Ref: CBCharacteristic?

    private func hexString(_ data: Data) -> String {
        data.isEmpty ? "(empty)" : data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    func toggle() {
        if isScanning {
            manager?.stopScan()
            isScanning = false
            return
        }
        found = []
        peripherals = [:]
        gattOutput = "Seleziona un dispositivo per connetterti."
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    func connect(_ item: Found) {
        guard let peripheral = peripherals[item.id] else { return }
        manager?.stopScan()
        isScanning = false
        gattOutput = "Connecting to \(item.name)..."
        peripheral.delegate = self
        manager?.connect(peripheral, options: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            gattOutput = "Bluetooth non pronto: state=\(central.state.rawValue)"
            return
        }
        central.scanForPeripherals(withServices: nil, options: nil)
        isScanning = true
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        peripherals[peripheral.identifier] = peripheral

        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "(no name)"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map(\.uuidString).joined(separator: ",") ?? "-"
        var mfg = "-"
        if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count >= 2 {
            let companyId = UInt16(data[1]) << 8 | UInt16(data[0])
            mfg = String(format: "0x%04X", companyId)
        }

        let entry = Found(id: peripheral.identifier, name: name, rssi: RSSI.intValue, services: services, mfgData: mfg)
        if let idx = found.firstIndex(where: { $0.id == entry.id }) {
            found[idx] = entry
        } else {
            found.append(entry)
        }
        found.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        gattOutput = "Connected to \(peripheral.name ?? "?"). Discovering services..."
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        gattOutput = "Connect failed: \(error?.localizedDescription ?? "unknown error")"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        gattOutput += "\n\n[disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")]"
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services, !services.isEmpty else {
            gattOutput = "No GATT services (error: \(error?.localizedDescription ?? "none"))"
            return
        }
        gattOutput = "Services found: \(services.count). Discovering characteristics..."
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = (service.characteristics ?? []).map { c -> String in
            var props: [String] = []
            if c.properties.contains(.read) { props.append("read") }
            if c.properties.contains(.write) { props.append("write") }
            if c.properties.contains(.writeWithoutResponse) { props.append("writeNoResp") }
            if c.properties.contains(.notify) { props.append("notify") }
            if c.properties.contains(.indicate) { props.append("indicate") }
            return "    \(c.uuid.uuidString)  [\(props.joined(separator: ","))]"
        }.joined(separator: "\n")
        gattOutput += "\n\nService \(service.uuid.uuidString):\n\(chars)"

        guard service.uuid == Self.fdabService else { return }
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case Self.fdabChar0001:
                peripheral.readValue(for: c)
            case Self.fdabChar0002:
                fdabChar0002Ref = c
                peripheral.setNotifyValue(true, for: c)
            case Self.fdabChar0003:
                fdabChar0003Ref = c
                peripheral.setNotifyValue(true, for: c)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            gattOutput += "\n[\(characteristic.uuid.uuidString)] error: \(error.localizedDescription)"
            return
        }
        gattOutput += "\n[\(characteristic.uuid.uuidString)] \(hexString(characteristic.value ?? Data()))"
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            gattOutput += "\n[\(characteristic.uuid.uuidString)] notify subscribe error: \(error.localizedDescription)"
        } else {
            gattOutput += "\n[\(characteristic.uuid.uuidString)] notify subscribed=\(characteristic.isNotifying)"
        }
    }

    // Test payloads for the unverified FDAB channel: empty write and a
    // single null byte, to see whether either provokes a structured
    // response (ACK, error frame, etc.) on the notify characteristics.
    func probeFDAB() {
        guard let peripheral = connectedPeripheral, let c2 = fdabChar0002Ref, let c3 = fdabChar0003Ref else {
            gattOutput += "\n\n[probe] not connected, or FDAB 0002/0003 not discovered yet"
            return
        }
        let payloads: [(String, Data)] = [("empty", Data()), ("null byte", Data([0x00]))]
        for (label, payload) in payloads {
            for (charLabel, char) in [("0002", c2), ("0003", c3)] {
                peripheral.writeValue(payload, for: char, type: .withoutResponse)
                gattOutput += "\n[probe] wrote \(label) to \(charLabel): \(hexString(payload))"
            }
        }
    }

    // The real first packet Gadgetbridge sends on classic-BT RFCOMM
    // (docs/PROTOCOL.md §2.1/§2.2): SPP-V1-framed OPCODE_READ on the
    // Version channel (channel id 0), plaintext, no payload. Preamble
    // BA DC FE / epilogue EF. If FDAB tunnels the same SPP framing over
    // BLE, this should provoke the same version-byte response.
    private func buildSppV1VersionReadPacket() -> Data {
        let channelId: UInt8 = 0x00       // Version
        let flags: UInt8 = 0x40           // needsResponse
        let opCode: UInt8 = 0x00          // READ
        let frameSerial: UInt8 = 0x00
        let dataType: UInt8 = 0x00        // PLAIN
        let subHeaderLength: UInt16 = 3   // opCode + frameSerial + dataType, no payload
        var packet = Data([0xBA, 0xDC, 0xFE, channelId, flags])
        packet.append(UInt8(subHeaderLength & 0xFF))
        packet.append(UInt8(subHeaderLength >> 8))
        packet.append(contentsOf: [opCode, frameSerial, dataType, 0xEF])
        return packet
    }

    func probeSppV1VersionRead() {
        guard let peripheral = connectedPeripheral, let c2 = fdabChar0002Ref, let c3 = fdabChar0003Ref else {
            gattOutput += "\n\n[probe] not connected, or FDAB 0002/0003 not discovered yet"
            return
        }
        let packet = buildSppV1VersionReadPacket()
        for (charLabel, char) in [("0002", c2), ("0003", c3)] {
            peripheral.writeValue(packet, for: char, type: .withoutResponse)
            gattOutput += "\n[probe] wrote SPP-V1 Version read to \(charLabel): \(hexString(packet))"
        }
    }
}
