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
                Button("Probe FE95 (SPP-V2 StartSession)") { bleScanner.probeBleV2StartSession() }
                Button("Copy") { UIPasteboard.general.string = bleScanner.gattOutput }
            }
            if let fixtureURL = bleScanner.fixtureURL {
                ShareLink("Export fixture (\(fixtureURL.lastPathComponent))", item: fixtureURL)
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

    // Gadgetbridge's known BLE-V2 transport (XiaomiUuids.java: "Mi Band 9
    // Active"), reused verbatim here -- matches this device's FE95 chars.
    // See docs/PROTOCOL.md §0a.
    private static let fe95Service = CBUUID(string: "FE95")
    private static let ble2ReadChar = CBUUID(string: "005E")  // notify (device -> phone)
    private static let ble2WriteChar = CBUUID(string: "005F") // write (phone -> device)
    private var ble2WriteRef: CBCharacteristic?

    // Automatic fixture logging (CLAUDE.md "Instrumentation": every
    // BLE frame gets a jsonl record -- direction, raw hex, monotonic
    // timestamp, decoded interpretation once known). Written to the app's
    // Documents dir, exported via the Share button once a session exists.
    @Published var fixtureURL: URL?
    private var fixtureHandle: FileHandle?
    private var fixtureSessionStart: TimeInterval?

    private func hexString(_ data: Data) -> String {
        data.isEmpty ? "(empty)" : data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func startFixtureSession(deviceName: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("session-\(formatter.string(from: Date())).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fixtureHandle = try? FileHandle(forWritingTo: url)
        fixtureSessionStart = ProcessInfo.processInfo.systemUptime

        writeFixtureLine([
            "meta": true,
            "device": deviceName,
            "captured_via": "ios/MFiCheck",
            "date": ISO8601DateFormatter().string(from: Date()),
        ])

        DispatchQueue.main.async { self.fixtureURL = url }
    }

    private func stopFixtureSession() {
        try? fixtureHandle?.close()
        fixtureHandle = nil
        fixtureSessionStart = nil
    }

    private func writeFixtureLine(_ record: [String: Any]) {
        guard let handle = fixtureHandle,
              let json = try? JSONSerialization.data(withJSONObject: record),
              var line = String(data: json, encoding: .utf8) else { return }
        line += "\n"
        handle.write(line.data(using: .utf8) ?? Data())
    }

    private func logFrame(direction: String, characteristic: CBUUID, data: Data? = nil, event: String? = nil) {
        guard let start = fixtureSessionStart else { return }
        var record: [String: Any] = [
            "t": ProcessInfo.processInfo.systemUptime - start,
            "direction": direction,
            "characteristic": characteristic.uuidString,
        ]
        if let data = data {
            record["hex"] = hexString(data)
            if let decoded = decodeSppV2Header(data) {
                record["decoded"] = decoded
            }
        }
        if let event = event {
            record["event"] = event
        }
        writeFixtureLine(record)
    }

    // Decodes the SPP-V2 outer header (docs/PROTOCOL.md §2.3) when present,
    // for both FE95's 005E/005F and (in case FDAB turns out to share the
    // framing after all) FDAB's 0002/0003.
    private func decodeSppV2Header(_ data: Data) -> [String: Any]? {
        guard data.count >= 8, data[data.startIndex] == 0xA5, data[data.startIndex + 1] == 0xA5 else { return nil }
        let bytes = [UInt8](data)
        let packetType = bytes[2] & 0x0F
        let sequence = bytes[3]
        let length = Int(bytes[4]) | (Int(bytes[5]) << 8)
        let checksum = Int(bytes[6]) | (Int(bytes[7]) << 8)
        let payload = bytes[8...]
        let packetTypeNames: [UInt8: String] = [1: "ACK", 2: "SessionConfig", 3: "Data"]
        var decoded: [String: Any] = [
            "packet_type": packetTypeNames[packetType] ?? String(packetType),
            "sequence": Int(sequence),
            "declared_length": length,
            "checksum": checksum,
            "actual_payload_len": payload.count,
        ]
        if packetType == 3, payload.count >= 2 {
            decoded["raw_channel"] = Int(payload[payload.startIndex]) & 0xF
            let opCode = payload[payload.startIndex + 1]
            let opCodeNames: [UInt8: String] = [1: "PLAINTEXT", 2: "ENCRYPTED"]
            decoded["op_code"] = opCodeNames[opCode] ?? String(opCode)
        }
        return decoded
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
        startFixtureSession(deviceName: peripheral.name ?? "?")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        gattOutput = "Connect failed: \(error?.localizedDescription ?? "unknown error")"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        gattOutput += "\n\n[disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")]"
        stopFixtureSession()
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

        switch service.uuid {
        case Self.fdabService:
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
        case Self.fe95Service:
            for c in service.characteristics ?? [] {
                switch c.uuid {
                case Self.ble2ReadChar:
                    peripheral.setNotifyValue(true, for: c)
                case Self.ble2WriteChar:
                    ble2WriteRef = c
                default:
                    break
                }
            }
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            gattOutput += "\n[\(characteristic.uuid.uuidString)] error: \(error.localizedDescription)"
            return
        }
        let value = characteristic.value ?? Data()
        gattOutput += "\n[\(characteristic.uuid.uuidString)] \(hexString(value))"
        logFrame(direction: "rx", characteristic: characteristic.uuid, data: value)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            gattOutput += "\n[\(characteristic.uuid.uuidString)] notify subscribe error: \(error.localizedDescription)"
        } else {
            gattOutput += "\n[\(characteristic.uuid.uuidString)] notify subscribed=\(characteristic.isNotifying)"
            logFrame(direction: "event", characteristic: characteristic.uuid, event: "notify subscribed=\(characteristic.isNotifying)")
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
                logFrame(direction: "tx", characteristic: char.uuid, data: payload)
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
            logFrame(direction: "tx", characteristic: char.uuid, data: packet)
        }
    }

    // CRC-16/ARC (poly 0x8005, init 0, reflected in/out, no xorout), ported
    // bit-for-bit from XiaomiSppPacketV2.calculatePayloadChecksum() (Java
    // `int` is a 32-bit two's-complement register; UInt32 here behaves the
    // same way under left-shift and bitwise ops).
    private func sppV2Checksum(_ payload: Data) -> UInt16 {
        var crc: UInt32 = 0
        for byte in payload {
            for j: UInt32 in 0..<8 {
                crc <<= 1
                let bBit = (UInt32(byte) >> j) & 1
                if (((crc >> 16) & 1) ^ bBit) == 1 {
                    crc ^= 0x8005
                }
            }
        }
        var reversed: UInt32 = 0
        var v = crc
        for _ in 0..<32 {
            reversed = (reversed << 1) | (v & 1)
            v >>= 1
        }
        return UInt16((reversed >> 16) & 0xFFFF)
    }

    private func buildSppV2Packet(packetType: UInt8, sequenceNumber: UInt8, payload: Data) -> Data {
        var packet = Data([0xA5, 0xA5, packetType & 0x0F, sequenceNumber])
        let length = UInt16(payload.count)
        packet.append(UInt8(length & 0xFF))
        packet.append(UInt8(length >> 8))
        let checksum = sppV2Checksum(payload)
        packet.append(UInt8(checksum & 0xFF))
        packet.append(UInt8(checksum >> 8))
        packet.append(payload)
        return packet
    }

    // Real Gadgetbridge BLE-V2 first message (XiaomiSppPacketV2.java:133-158,
    // "from packet dump of official app"): SessionConfig StartSessionRequest,
    // opcode 1, TLVs VERSION=01.00.00, MAX_PACKET_SIZE=0xfc00, TX_WIN=0x0020,
    // SEND_TIMEOUT=0x2710.
    private func buildSessionConfigStartRequestPayload() -> Data {
        var payload = Data([0x01])                              // opcode: START_SESSION_REQUEST
        payload.append(contentsOf: [0x01, 0x03, 0x00, 0x01, 0x00, 0x00]) // KEY_VERSION
        payload.append(contentsOf: [0x02, 0x02, 0x00, 0x00, 0xFC])       // KEY_MAX_PACKET_SIZE
        payload.append(contentsOf: [0x03, 0x02, 0x00, 0x20, 0x00])       // KEY_TX_WIN
        payload.append(contentsOf: [0x04, 0x02, 0x00, 0x10, 0x27])       // KEY_SEND_TIMEOUT
        return payload
    }

    func probeBleV2StartSession() {
        guard let peripheral = connectedPeripheral, let writeChar = ble2WriteRef else {
            gattOutput += "\n\n[probe] not connected, or FE95 005F not discovered yet"
            return
        }
        let packet = buildSppV2Packet(packetType: 2, sequenceNumber: 0, payload: buildSessionConfigStartRequestPayload())
        peripheral.writeValue(packet, for: writeChar, type: .withoutResponse)
        gattOutput += "\n[probe] wrote SPP-V2 StartSessionRequest to 005F: \(hexString(packet))"
        logFrame(direction: "tx", characteristic: writeChar.uuid, data: packet)
    }
}
