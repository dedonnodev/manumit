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
// Minimal hand-rolled protobuf wire format (proto2, `proto/xiaomi.proto`) --
// just enough to build/parse the auth messages needed for the §3 handshake
// (Command/Auth/PhoneNonce/WatchNonce/AuthStep3/AuthDeviceInfo). Not a
// general protobuf library: no swift-protobuf dependency because that needs
// an SPM package reference wired into the .xcodeproj, which can't be
// verified without a Mac to actually build it. If the app grows past the
// handful of auth messages, switch to swift-protobuf against the vendored
// `proto/xiaomi.proto` instead of hand-extending this.

import Foundation

struct ProtoWriter {
    private(set) var data = Data()

    mutating func putVarint(_ field: Int, _ value: UInt64) {
        writeTag(field, wireType: 0)
        writeVarint(value)
    }

    mutating func putBytes(_ field: Int, _ value: Data) {
        writeTag(field, wireType: 2)
        writeVarint(UInt64(value.count))
        data.append(value)
    }

    mutating func putString(_ field: Int, _ value: String) {
        putBytes(field, Data(value.utf8))
    }

    /// Embedded messages use the same length-delimited wire encoding as bytes.
    mutating func putMessage(_ field: Int, _ value: Data) {
        putBytes(field, value)
    }

    /// proto2 `float`: fixed32 wire type, IEEE-754 bit pattern, little-endian.
    mutating func putFloat(_ field: Int, _ value: Float) {
        writeTag(field, wireType: 5)
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    private mutating func writeTag(_ field: Int, wireType: Int) {
        writeVarint(UInt64((field << 3) | wireType))
    }

    private mutating func writeVarint(_ value: UInt64) {
        var v = value
        while true {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            data.append(byte)
            if v == 0 { break }
        }
    }
}

struct ProtoReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var hasMore: Bool { offset < bytes.count }

    mutating func readTag() -> (field: Int, wireType: Int) {
        let tag = readVarint()
        return (Int(tag >> 3), Int(tag & 0x7))
    }

    // Bounds-checked: `bytes` comes straight off the BLE wire (a system
    // boundary), and an unexpected/malformed message must not crash the app
    // -- stop parsing and let the caller's field-presence checks fail
    // instead of trapping on an out-of-range subscript.
    mutating func readVarint() -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return result
    }

    mutating func readBytes() -> Data {
        let len = Int(readVarint())
        guard len >= 0, offset + len <= bytes.count else {
            offset = bytes.count
            return Data()
        }
        let d = Data(bytes[offset..<offset + len])
        offset += len
        return d
    }

    mutating func skip(wireType: Int) {
        switch wireType {
        case 0: _ = readVarint()
        case 1: offset += 8
        case 2: _ = readBytes()
        case 5: offset += 4
        default: break
        }
    }
}

/// Builders/parsers for exactly the `xiaomi.Command` shapes the §3 auth
/// handshake needs. Field numbers match `proto/xiaomi.proto` verbatim.
enum XiaomiProto {
    struct DecodedCommand {
        var type: UInt64
        var subtype: UInt64
        var authBytes: Data?
        var systemBytes: Data?
        var healthBytes: Data?
        var status: UInt64?
    }

    struct DecodedWatchNonce {
        var nonce: Data
        var hmac: Data
    }

    struct DecodedBattery {
        var level: UInt64?
        var state: UInt64?
    }

    /// One `XiaomiActivityFileId` (§6.1): 7 bytes, little-endian.
    struct DecodedActivityFileId {
        var timestamp: Date
        var timezoneBlocks: Int8 // 15-min blocks, signed (west of UTC is negative)
        var version: UInt8
        var flags: UInt8 // bit7=type bits1-6=subtype bits0-1=detailType -- raw, not decomposed (M6+)
    }

    // -- build (phone -> watch) --

    static func command(type: UInt64, subtype: UInt64, authField: Data) -> Data {
        var w = ProtoWriter()
        w.putVarint(1, type)
        w.putVarint(2, subtype)
        w.putBytes(3, authField)
        return w.data
    }

    /// GET-style requests (e.g. System/Battery, System/DeviceInfo) send just
    /// type+subtype, no other field -- matches Gadgetbridge's
    /// `sendCommand(taskName, type, subtype)` overload, which builds a bare
    /// `Command` with nothing else set (`XiaomiSupport.java:423-431`).
    static func commandTypeSubtypeOnly(type: UInt64, subtype: UInt64) -> Data {
        var w = ProtoWriter()
        w.putVarint(1, type)
        w.putVarint(2, subtype)
        return w.data
    }

    /// `Command.health` is field 10 -- carries the `Health` submessage for
    /// every type=8 request/response (§6.2).
    static func commandWithHealth(type: UInt64, subtype: UInt64, healthField: Data) -> Data {
        var w = ProtoWriter()
        w.putVarint(1, type)
        w.putVarint(2, subtype)
        w.putBytes(10, healthField)
        return w.data
    }

    /// `Health{activitySyncRequestToday=ActivitySyncRequestToday{unknown1=0}}`
    /// -- the M5 TODAY file-id request (`XiaomiHealthService.java:802-814`,
    /// `Health.activitySyncRequestToday`=field 5,
    /// `ActivitySyncRequestToday.unknown1`=field 1).
    static func healthActivitySyncRequestToday() -> Data {
        var req = ProtoWriter()
        req.putVarint(1, 0) // unknown1, must be serialized explicitly as 0
        var health = ProtoWriter()
        health.putBytes(5, req.data)
        return health.data
    }

    static func authWithPhoneNonce(_ nonce: Data) -> Data {
        var pn = ProtoWriter(); pn.putBytes(1, nonce)
        var auth = ProtoWriter(); auth.putBytes(30, pn.data)
        return auth.data
    }

    static func authWithStep3(encryptedNonces: Data, encryptedDeviceInfo: Data) -> Data {
        var step3 = ProtoWriter()
        step3.putBytes(1, encryptedNonces)
        step3.putBytes(2, encryptedDeviceInfo)
        var auth = ProtoWriter(); auth.putBytes(32, step3.data)
        return auth.data
    }

    static func authDeviceInfo(phoneApiLevel: Float, phoneName: String, unknown3: UInt64, region: String) -> Data {
        var w = ProtoWriter()
        w.putVarint(1, 0) // unknown1, must be serialized explicitly as 0
        w.putFloat(2, phoneApiLevel)
        w.putString(3, phoneName)
        w.putVarint(4, unknown3)
        w.putString(5, region)
        return w.data
    }

    // -- parse (watch -> phone) --

    static func decodeCommand(_ data: Data) -> DecodedCommand {
        var r = ProtoReader(data)
        var type: UInt64 = 0, subtype: UInt64 = 0
        var authBytes: Data?
        var systemBytes: Data?
        var healthBytes: Data?
        var status: UInt64?
        while r.hasMore {
            let (field, wireType) = r.readTag()
            switch (field, wireType) {
            case (1, 0): type = r.readVarint()
            case (2, 0): subtype = r.readVarint()
            case (3, 2): authBytes = r.readBytes()
            case (4, 2): systemBytes = r.readBytes()
            case (10, 2): healthBytes = r.readBytes()
            case (100, 0): status = r.readVarint()
            default: r.skip(wireType: wireType)
            }
        }
        return DecodedCommand(type: type, subtype: subtype, authBytes: authBytes, systemBytes: systemBytes, healthBytes: healthBytes, status: status)
    }

    /// `System.power.battery` (fields 2, 1 respectively) -- the only System
    /// payload this app decodes so far (M4).
    static func decodeBattery(fromSystem systemBytes: Data) -> DecodedBattery? {
        var sr = ProtoReader(systemBytes)
        var powerBytes: Data?
        while sr.hasMore {
            let (field, wireType) = sr.readTag()
            if field == 2, wireType == 2 {
                powerBytes = sr.readBytes()
            } else {
                sr.skip(wireType: wireType)
            }
        }
        guard let powerBytes = powerBytes else { return nil }

        var pr = ProtoReader(powerBytes)
        var batteryBytes: Data?
        while pr.hasMore {
            let (field, wireType) = pr.readTag()
            if field == 1, wireType == 2 {
                batteryBytes = pr.readBytes()
            } else {
                pr.skip(wireType: wireType)
            }
        }
        guard let batteryBytes = batteryBytes else { return nil }

        var br = ProtoReader(batteryBytes)
        var level: UInt64?, state: UInt64?
        while br.hasMore {
            let (field, wireType) = br.readTag()
            switch (field, wireType) {
            case (1, 0): level = br.readVarint()
            case (2, 0): state = br.readVarint()
            default: br.skip(wireType: wireType)
            }
        }
        return DecodedBattery(level: level, state: state)
    }

    /// `Health.activityRequestFileIds` (field 2) -- same field Gadgetbridge
    /// reuses for both the TODAY/PAST response and the per-file request
    /// (`XiaomiHealthService.java:135-136`). Response bytes are back-to-back
    /// 7-byte `XiaomiActivityFileId` entries (§6.1); `nil` if the field is
    /// missing or its length isn't a multiple of 7 -- don't guess at framing.
    static func decodeActivityFileIds(fromHealth healthBytes: Data) -> [DecodedActivityFileId]? {
        var hr = ProtoReader(healthBytes)
        var idBytes: Data?
        while hr.hasMore {
            let (field, wireType) = hr.readTag()
            if field == 2, wireType == 2 {
                idBytes = hr.readBytes()
            } else {
                hr.skip(wireType: wireType)
            }
        }
        guard let idBytes = idBytes, idBytes.count % 7 == 0 else { return nil }

        var result: [DecodedActivityFileId] = []
        var offset = idBytes.startIndex
        while offset < idBytes.endIndex {
            let ts = UInt32(idBytes[offset])
                | UInt32(idBytes[offset + 1]) << 8
                | UInt32(idBytes[offset + 2]) << 16
                | UInt32(idBytes[offset + 3]) << 24
            let tz = Int8(bitPattern: idBytes[offset + 4])
            let version = idBytes[offset + 5]
            let flags = idBytes[offset + 6]
            result.append(DecodedActivityFileId(
                timestamp: Date(timeIntervalSince1970: TimeInterval(ts)),
                timezoneBlocks: tz,
                version: version,
                flags: flags
            ))
            offset += 7
        }
        return result
    }

    static func decodeWatchNonce(fromAuth authBytes: Data) -> DecodedWatchNonce? {
        var r = ProtoReader(authBytes)
        var watchNonceBytes: Data?
        while r.hasMore {
            let (field, wireType) = r.readTag()
            if field == 31, wireType == 2 {
                watchNonceBytes = r.readBytes()
            } else {
                r.skip(wireType: wireType)
            }
        }
        guard let wn = watchNonceBytes else { return nil }
        var wr = ProtoReader(wn)
        var nonce: Data?, hmac: Data?
        while wr.hasMore {
            let (field, wireType) = wr.readTag()
            switch (field, wireType) {
            case (1, 2): nonce = wr.readBytes()
            case (2, 2): hmac = wr.readBytes()
            default: wr.skip(wireType: wireType)
            }
        }
        guard let n = nonce, let h = hmac else { return nil }
        return DecodedWatchNonce(nonce: n, hmac: h)
    }

    // No Swift toolchain available in the environment these changes were
    // authored in (no XCTest run possible outside Xcode) -- same situation
    // as `SppV2Codec.selfTest()`. Asserts run for real the first time the
    // app launches in DEBUG.
    static func selfTest() {
        // TODAY request: Command{type=8,subtype=1,health=Health{
        // activitySyncRequestToday=ActivitySyncRequestToday{unknown1=0}}},
        // hand-verified byte-by-byte against the field numbers above.
        let built = commandWithHealth(type: 8, subtype: 1, healthField: healthActivitySyncRequestToday())
        let expected = Data([0x08, 0x08, 0x10, 0x01, 0x52, 0x04, 0x2A, 0x02, 0x08, 0x00])
        assert(built == expected, "M5 TODAY request encoding changed: \(built as NSData) != \(expected as NSData)")

        // Response round-trip: two synthetic 7-byte file IDs packed into
        // Health.activityRequestFileIds (field 2), wrapped in a Command like
        // a real watch reply, decoded back through decodeCommand +
        // decodeActivityFileIds.
        let entry1 = Data([0x64, 0x00, 0x00, 0x00, 0x04, 0x06, 0x00]) // ts=100, tz=4, version=6, flags=0x00
        let entry2 = Data([0x65, 0x00, 0x00, 0x00, 0xEC, 0x07, 0x81]) // ts=101, tz=-20, version=7, flags=0x81
        var healthWriter = ProtoWriter()
        healthWriter.putBytes(2, entry1 + entry2)
        var cmdWriter = ProtoWriter()
        cmdWriter.putVarint(1, 8)
        cmdWriter.putVarint(2, 1)
        cmdWriter.putBytes(10, healthWriter.data)

        let decoded = decodeCommand(cmdWriter.data)
        assert(decoded.type == 8 && decoded.subtype == 1)
        guard let healthBytes = decoded.healthBytes,
              let fileIds = decodeActivityFileIds(fromHealth: healthBytes) else {
            assertionFailure("M5 response round-trip should decode"); return
        }
        assert(fileIds.count == 2)
        assert(fileIds[0].timestamp.timeIntervalSince1970 == 100)
        assert(fileIds[0].timezoneBlocks == 4)
        assert(fileIds[0].version == 6)
        assert(fileIds[0].flags == 0x00)
        assert(fileIds[1].timestamp.timeIntervalSince1970 == 101)
        assert(fileIds[1].timezoneBlocks == -20)
        assert(fileIds[1].version == 7)
        assert(fileIds[1].flags == 0x81)

        // Malformed length (not a multiple of 7) must fail loudly, not guess.
        var badHealthWriter = ProtoWriter()
        badHealthWriter.putBytes(2, Data([0, 0, 0, 0, 0]))
        assert(decodeActivityFileIds(fromHealth: badHealthWriter.data) == nil)

        // Missing field entirely.
        assert(decodeActivityFileIds(fromHealth: Data()) == nil)
    }
}
