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
// SPP-V2 packet framing (docs/PROTOCOL.md §2.3), reused verbatim over BLE
// (§0a). Port of src/miband/protocol.py's encode_v2/decode_v2 -- keep the
// two in sync if the framing ever changes.

import Foundation

struct SppV2Packet: Equatable {
    let packetType: UInt8
    let sequence: UInt8
    let payload: Data
}

enum SppV2Error: Error, CustomStringConvertible {
    case badPreamble(UInt8, UInt8)
    case badChecksum(expected: UInt16, actual: UInt16)

    var description: String {
        switch self {
        case let .badPreamble(a, b):
            return String(format: "bad SPP-V2 preamble: %02X %02X", a, b)
        case let .badChecksum(expected, actual):
            return String(format: "SPP-V2 checksum mismatch: header says %#06x, computed %#06x", expected, actual)
        }
    }
}

enum SppV2Codec {
    static let packetTypeAck: UInt8 = 1
    static let packetTypeSessionConfig: UInt8 = 2
    static let packetTypeData: UInt8 = 3

    /// CRC-16/ARC: poly 0x8005 reflected (0xA001), init 0, no xorout (§2.3).
    static func crc16Arc(_ payload: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in payload {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }

    static func encode(_ packet: SppV2Packet) -> Data {
        var out = Data([0xA5, 0xA5, packet.packetType, packet.sequence])
        let length = UInt16(packet.payload.count)
        out.append(UInt8(length & 0xFF))
        out.append(UInt8(length >> 8))
        let crc = crc16Arc(packet.payload)
        out.append(UInt8(crc & 0xFF))
        out.append(UInt8(crc >> 8))
        out.append(packet.payload)
        return out
    }

    /// Decodes one packet from the start of `buf`. Returns `(packet,
    /// bytesConsumed)`, or `nil` if `buf` doesn't yet hold a full packet --
    /// callers buffer bytes across BLE notify events and call this again
    /// (§2.3, confirmed on hardware: a single payload can arrive split
    /// across two separate notify events).
    static func decode(_ buf: Data) throws -> (SppV2Packet, Int)? {
        guard buf.count >= 8 else { return nil }
        let bytes = [UInt8](buf)
        guard bytes[0] == 0xA5, bytes[1] == 0xA5 else {
            throw SppV2Error.badPreamble(bytes[0], bytes[1])
        }
        let packetType = bytes[2]
        let sequence = bytes[3]
        let length = Int(bytes[4]) | (Int(bytes[5]) << 8)
        let declaredChecksum = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
        let total = 8 + length
        guard buf.count >= total else { return nil }
        let payload = buf.subdata(in: 8..<total)
        let actual = crc16Arc(payload)
        guard actual == declaredChecksum else {
            throw SppV2Error.badChecksum(expected: declaredChecksum, actual: actual)
        }
        return (SppV2Packet(packetType: packetType, sequence: sequence, payload: payload), total)
    }

    /// Debug-only self-check using the same real captured bytes as
    /// tests/test_protocol.py, so a framing regression fails loudly instead
    /// of silently at handshake time.
    static func selfTest() {
        func hex(_ s: String) -> Data {
            var data = Data()
            var chars = Array(s.replacingOccurrences(of: " ", with: ""))
            while chars.count >= 2 {
                data.append(UInt8(String(chars[0...1]), radix: 16)!)
                chars.removeFirst(2)
            }
            return data
        }

        let sessionConfigResponse = hex(
            "A5 A5 02 00 16 00 15 19 02 01 03 00 03 00 41 02 02 00 00 80 " +
            "03 02 00 03 00 04 02 00 80 3E"
        )
        let ackSeq0 = hex("A5 A5 01 00 00 00 00 00")
        let startSessionRequest = hex(
            "A5 A5 02 00 16 00 1D 4D 01 01 03 00 01 00 00 02 02 00 00 FC " +
            "03 02 00 20 00 04 02 00 10 27"
        )

        do {
            guard let (pkt, consumed) = try decode(sessionConfigResponse) else {
                assertionFailure("sessionConfigResponse should decode fully"); return
            }
            assert(consumed == sessionConfigResponse.count)
            assert(pkt.packetType == packetTypeSessionConfig)
            assert(pkt.sequence == 0)
            assert(pkt.payload.count == 22)

            guard let (ack, ackConsumed) = try decode(ackSeq0) else {
                assertionFailure("ackSeq0 should decode fully"); return
            }
            assert(ackConsumed == 8)
            assert(ack.packetType == packetTypeAck)
            assert(ack.payload.isEmpty)

            let encoded = encode(SppV2Packet(
                packetType: packetTypeSessionConfig,
                sequence: 0,
                payload: hex("01 01 03 00 01 00 00 02 02 00 00 FC 03 02 00 20 00 04 02 00 10 27")
            ))
            assert(encoded == startSessionRequest)

            let incomplete = try decode(sessionConfigResponse.prefix(10))
            assert(incomplete == nil)
        } catch {
            assertionFailure("SppV2Codec.selfTest failed: \(error)")
        }
    }
}
