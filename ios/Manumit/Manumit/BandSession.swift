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
// BLE-GATT transport (FE95/005E/005F, docs/PROTOCOL.md §0a) + SPP-V2
// session framing + the §3 auth handshake, wired together. This is M3:
// scan -> connect -> StartSessionRequest -> PhoneNonce -> verify WatchNonce
// -> AuthStep3 -> authenticated.

import CoreBluetooth
import Foundation
import UIKit

enum HandshakeState: Equatable {
    case idle
    case scanning
    case connecting
    case discoveringServices
    case startingSession
    case waitingWatchNonce
    case sendingAuthStep3
    case waitingAuthAck
    case authenticated
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .scanning: return "Scanning..."
        case .connecting: return "Connecting..."
        case .discoveringServices: return "Discovering services..."
        case .startingSession: return "Starting SPP-V2 session..."
        case .waitingWatchNonce: return "Waiting for watch nonce..."
        case .sendingAuthStep3: return "Sending AuthStep3..."
        case .waitingAuthAck: return "Waiting for auth ack..."
        case .authenticated: return "Authenticated"
        case let .failed(reason): return "Failed: \(reason)"
        }
    }
}

final class BandSession: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published private(set) var state: HandshakeState = .idle
    @Published private(set) var log: [String] = []
    @Published private(set) var fixtureURL: URL?

    private static let deviceNameRegex = try! NSRegularExpression(pattern: "^Xiaomi Smart Band 10 [0-9A-F]{4}$")
    private static let serviceUUID = CBUUID(string: "FE95")
    private static let notifyCharUUID = CBUUID(string: "005E") // watch -> phone
    private static let writeCharUUID = CBUUID(string: "005F")  // phone -> watch

    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?

    private var secretKey = Data()
    private var phoneNonce = Data()
    private var derivedKeys: AuthCrypto.DerivedKeys?

    private var rxBuffer = Data()
    private var sendSeq: UInt8 = 0

    private var fixtureHandle: FileHandle?
    private var fixtureStart: TimeInterval?

    func start(secretKeyHex: String) {
        guard let key = Data(hexString: secretKeyHex), key.count == 16 else {
            state = .failed("auth key must be 32 hex chars (16 bytes)")
            return
        }
        secretKey = key
        rxBuffer = Data()
        sendSeq = 0
        derivedKeys = nil
        log = []
        state = .scanning
        appendLog("scanning for Band 10...")
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            state = .failed("Bluetooth not ready (state=\(central.state.rawValue))")
            return
        }
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let range = NSRange(name.startIndex..., in: name)
        guard Self.deviceNameRegex.firstMatch(in: name, range: range) != nil else { return }

        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting
        appendLog("found \(name), connecting...")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .failed("connect failed: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        appendLog("disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        stopFixtureSession()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .discoveringServices
        startFixtureSession(deviceName: peripheral.name ?? "?")
        peripheral.discoverServices([Self.serviceUUID])
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            state = .failed("FE95 service not found (error: \(error?.localizedDescription ?? "none"))")
            return
        }
        peripheral.discoverCharacteristics([Self.notifyCharUUID, Self.writeCharUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else {
            state = .failed("no characteristics on FE95 (error: \(error?.localizedDescription ?? "none"))")
            return
        }
        for c in chars {
            if c.uuid == Self.notifyCharUUID {
                peripheral.setNotifyValue(true, for: c)
            } else if c.uuid == Self.writeCharUUID {
                writeChar = c
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.notifyCharUUID else { return }
        if let error = error {
            state = .failed("notify subscribe failed: \(error.localizedDescription)")
            return
        }
        logEvent(characteristic: characteristic.uuid, event: "notify subscribed=\(characteristic.isNotifying)")
        startSppV2Session()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            appendLog("notify error: \(error.localizedDescription)")
            return
        }
        guard characteristic.uuid == Self.notifyCharUUID, let value = characteristic.value else { return }
        logRaw(direction: "rx", characteristic: characteristic.uuid, data: value)
        rxBuffer.append(value)
        drainBuffer()
    }

    // MARK: - SPP-V2 session

    private func nextSeq() -> UInt8 {
        defer { sendSeq &+= 1 }
        return sendSeq
    }

    private func sendPacket(type: UInt8, sequence: UInt8, payload: Data) {
        guard let peripheral = peripheral, let writeChar = writeChar else { return }
        let packet = SppV2Codec.encode(SppV2Packet(packetType: type, sequence: sequence, payload: payload))
        peripheral.writeValue(packet, for: writeChar, type: .withoutResponse)
        logRaw(direction: "tx", characteristic: writeChar.uuid, data: packet)
    }

    private func sendData(rawChannel: UInt8, opCode: UInt8, body: Data) {
        sendPacket(type: SppV2Codec.packetTypeData, sequence: nextSeq(), payload: Data([rawChannel, opCode]) + body)
    }

    private func sendAck(matching sequence: UInt8) {
        sendPacket(type: SppV2Codec.packetTypeAck, sequence: sequence, payload: Data())
    }

    // Real Gadgetbridge BLE-V2 first message (docs/PROTOCOL.md §0a): opcode
    // START_SESSION_REQUEST=1, TLVs VERSION/MAX_PACKET_SIZE/TX_WIN/SEND_TIMEOUT.
    private func startSppV2Session() {
        state = .startingSession
        var payload = Data([0x01])
        payload.append(contentsOf: [0x01, 0x03, 0x00, 0x01, 0x00, 0x00]) // VERSION
        payload.append(contentsOf: [0x02, 0x02, 0x00, 0x00, 0xFC])       // MAX_PACKET_SIZE
        payload.append(contentsOf: [0x03, 0x02, 0x00, 0x20, 0x00])       // TX_WIN
        payload.append(contentsOf: [0x04, 0x02, 0x00, 0x10, 0x27])       // SEND_TIMEOUT
        sendPacket(type: SppV2Codec.packetTypeSessionConfig, sequence: nextSeq(), payload: payload)
    }

    private func drainBuffer() {
        while true {
            do {
                guard let (packet, consumed) = try SppV2Codec.decode(rxBuffer) else { break }
                rxBuffer.removeFirst(consumed)
                logDecoded(packet: packet)
                handle(packet: packet)
            } catch {
                appendLog("frame decode error: \(error), dropping buffer")
                rxBuffer.removeAll()
                break
            }
        }
    }

    private func handle(packet: SppV2Packet) {
        switch packet.packetType {
        case SppV2Codec.packetTypeSessionConfig:
            if state == .startingSession {
                appendLog("session started, sending PhoneNonce")
                sendPhoneNonce()
            }
        case SppV2Codec.packetTypeAck:
            break // acks of our own sends; nothing to do for this milestone
        case SppV2Codec.packetTypeData:
            // Every received Data packet must be ACKed, regardless of
            // channel/content (§2.3) -- do this before any parsing so a
            // decode failure below can't leave the watch waiting forever.
            sendAck(matching: packet.sequence)
            guard packet.payload.count >= 2 else { return }
            let rawChannel = packet.payload[packet.payload.startIndex] & 0xF
            let opCode = packet.payload[packet.payload.startIndex + 1]
            let body = packet.payload.subdata(in: (packet.payload.startIndex + 2)..<packet.payload.endIndex)
            guard rawChannel == 1, opCode == 1 else { return } // Auth is always plaintext Protobuf
            handleAuthCommand(body: body)
        default:
            break
        }
    }

    private func handleAuthCommand(body: Data) {
        let command = XiaomiProto.decodeCommand(body)
        guard command.type == 1 else { return }
        switch (command.subtype, state) {
        case (26, .waitingWatchNonce):
            guard let authBytes = command.authBytes,
                  let watchNonce = XiaomiProto.decodeWatchNonce(fromAuth: authBytes) else {
                state = .failed("could not parse WatchNonce")
                return
            }
            appendLog("got WatchNonce, deriving keys")
            receivedWatchNonce(nonce: watchNonce.nonce, hmac: watchNonce.hmac)
        case (27, .waitingAuthAck):
            if let status = command.status, status != 0 {
                state = .failed("watch rejected AuthStep3 (status=\(status))")
            } else {
                appendLog("watch acked AuthStep3 -- authenticated")
                state = .authenticated
            }
        default:
            break
        }
    }

    // MARK: - §3 handshake

    private func sendPhoneNonce() {
        phoneNonce = AuthCrypto.randomBytes(16)
        let authField = XiaomiProto.authWithPhoneNonce(phoneNonce)
        let cmd = XiaomiProto.command(type: 1, subtype: 26, authField: authField)
        sendData(rawChannel: 1, opCode: 1, body: cmd)
        state = .waitingWatchNonce
    }

    private func receivedWatchNonce(nonce watchNonce: Data, hmac watchHmac: Data) {
        let derived = AuthCrypto.deriveKeys(phoneNonce: phoneNonce, watchNonce: watchNonce, secretKey: secretKey)
        guard AuthCrypto.confirmWatchHmac(decryptionKey: derived.decryptionKey, watchNonce: watchNonce, phoneNonce: phoneNonce, watchHmac: watchHmac) else {
            state = .failed("watch HMAC mismatch -- wrong auth key, or wrong nonce order")
            return
        }
        derivedKeys = derived
        state = .sendingAuthStep3

        let apiLevel = Float(UIDevice.current.systemVersion) ?? 17.0
        let deviceInfo = XiaomiProto.authDeviceInfo(
            phoneApiLevel: apiLevel,
            phoneName: UIDevice.current.model,
            unknown3: 224,
            region: Locale.current.region?.identifier ?? "US"
        )
        // §4.2 AES-CTR, not §4.1 AES-CCM: this session is SPP-V2 (BLE-V2
        // path), confirmed on hardware, see docs/PROTOCOL.md §0a.
        let encryptedDeviceInfo = AuthCrypto.ctrCrypt(key: derived.encryptionKey, data: deviceInfo)
        let encryptedNonces = AuthCrypto.hmacSha256(key: derived.encryptionKey, message: phoneNonce + watchNonce)
        let authField = XiaomiProto.authWithStep3(encryptedNonces: encryptedNonces, encryptedDeviceInfo: encryptedDeviceInfo)
        let cmd = XiaomiProto.command(type: 1, subtype: 27, authField: authField)
        appendLog("sending AuthStep3")
        sendData(rawChannel: 1, opCode: 1, body: cmd)
        state = .waitingAuthAck
    }

    // MARK: - Fixture logging (CLAUDE.md "Instrumentation")

    private func startFixtureSession(deviceName: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("session-\(formatter.string(from: Date())).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fixtureHandle = try? FileHandle(forWritingTo: url)
        fixtureStart = ProcessInfo.processInfo.systemUptime
        writeFixtureLine([
            "meta": true,
            "device": deviceName,
            "captured_via": "ios/Manumit",
            "date": ISO8601DateFormatter().string(from: Date()),
        ])
        DispatchQueue.main.async { self.fixtureURL = url }
    }

    private func stopFixtureSession() {
        try? fixtureHandle?.close()
        fixtureHandle = nil
        fixtureStart = nil
    }

    private func writeFixtureLine(_ record: [String: Any]) {
        guard let handle = fixtureHandle,
              let json = try? JSONSerialization.data(withJSONObject: record),
              var line = String(data: json, encoding: .utf8) else { return }
        line += "\n"
        handle.write(line.data(using: .utf8) ?? Data())
    }

    private func hexString(_ data: Data) -> String {
        data.isEmpty ? "" : data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func logRaw(direction: String, characteristic: CBUUID, data: Data) {
        guard let start = fixtureStart else { return }
        writeFixtureLine([
            "t": ProcessInfo.processInfo.systemUptime - start,
            "direction": direction,
            "characteristic": characteristic.uuidString,
            "hex": hexString(data),
        ])
    }

    private func logEvent(characteristic: CBUUID, event: String) {
        guard let start = fixtureStart else { return }
        writeFixtureLine([
            "t": ProcessInfo.processInfo.systemUptime - start,
            "direction": "event",
            "characteristic": characteristic.uuidString,
            "event": event,
        ])
    }

    private func logDecoded(packet: SppV2Packet) {
        guard let start = fixtureStart else { return }
        let typeNames: [UInt8: String] = [1: "ACK", 2: "SessionConfig", 3: "Data"]
        var decoded: [String: Any] = [
            "packet_type": typeNames[packet.packetType] ?? String(packet.packetType),
            "sequence": Int(packet.sequence),
            "payload_len": packet.payload.count,
        ]
        if packet.packetType == SppV2Codec.packetTypeData, packet.payload.count >= 2 {
            decoded["raw_channel"] = Int(packet.payload[packet.payload.startIndex] & 0xF)
            decoded["op_code"] = packet.payload[packet.payload.startIndex + 1] == 1 ? "PLAINTEXT" : "ENCRYPTED"
        }
        writeFixtureLine([
            "t": ProcessInfo.processInfo.systemUptime - start,
            "direction": "rx",
            "decoded": decoded,
        ])
    }

    private func appendLog(_ line: String) {
        DispatchQueue.main.async { self.log.append(line) }
    }
}

extension Data {
    init?(hexString: String) {
        let clean = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count % 2 == 0, !clean.isEmpty else { return nil }
        var data = Data(capacity: clean.count / 2)
        var chars = Array(clean)
        while chars.count >= 2 {
            guard let byte = UInt8(String(chars[0...1]), radix: 16) else { return nil }
            data.append(byte)
            chars.removeFirst(2)
        }
        self = data
    }
}
