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

    mutating func readVarint() -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
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
        var status: UInt64?
    }

    struct DecodedWatchNonce {
        var nonce: Data
        var hmac: Data
    }

    // -- build (phone -> watch) --

    static func command(type: UInt64, subtype: UInt64, authField: Data) -> Data {
        var w = ProtoWriter()
        w.putVarint(1, type)
        w.putVarint(2, subtype)
        w.putBytes(3, authField)
        return w.data
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
        var status: UInt64?
        while r.hasMore {
            let (field, wireType) = r.readTag()
            switch (field, wireType) {
            case (1, 0): type = r.readVarint()
            case (2, 0): subtype = r.readVarint()
            case (3, 2): authBytes = r.readBytes()
            case (100, 0): status = r.readVarint()
            default: r.skip(wireType: wireType)
            }
        }
        return DecodedCommand(type: type, subtype: subtype, authBytes: authBytes, status: status)
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
}
