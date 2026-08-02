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

import XCTest
@testable import Manumit

final class DailySummaryParserTests: XCTestCase {
    // Builds a full 32-slot v5 body with every validity bit set, and known
    // values in the slots this app reads (0 steps, 1 activeCalories, 3
    // restingHR, 4/5 maxHR+ts, 6/7 minHR+ts, 8 avgHR, 13 totalCalories).
    // Every other slot is zero-filled bytes of the right width per
    // DailySummaryParser.java's SLOTS table.
    private func makeBody(headerBits: [Bool] = Array(repeating: true, count: 32)) -> Data {
        var header: [UInt8] = [0, 0, 0, 0]
        for (i, bit) in headerBits.enumerated() where bit {
            header[i / 8] |= UInt8(1 << (7 - (i % 8)))
        }
        var body = Data()
        func u8(_ v: UInt8) { body.append(v) }
        func u16(_ v: UInt16) { body.append(UInt8(v & 0xFF)); body.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) {
            body.append(UInt8(v & 0xFF)); body.append(UInt8((v >> 8) & 0xFF))
            body.append(UInt8((v >> 16) & 0xFF)); body.append(UInt8((v >> 24) & 0xFF))
        }
        u32(8000)      // 0 steps
        u16(300)       // 1 activeCalories
        u8(0)          // 2 reserved
        u8(58)         // 3 restingHR
        u8(142)        // 4 maxHR
        u32(1700000100) // 5 maxHRTs
        u8(50)         // 6 minHR
        u32(1700000000) // 7 minHRTs
        u8(72)         // 8 avgHR
        u8(0); u8(0); u8(0) // 9,10,11 stress avg/max/min
        body.append(contentsOf: [0, 0, 0]) // 12 standing bitmap (3 bytes)
        u16(1800)      // 13 totalCalories
        u16(0)         // 14 recovery hours
        u8(0)          // 15 reserved
        u8(0); u32(0); u8(0); u32(0); u8(0) // 16,17,18,19,20 SpO2
        u16(0); u16(0) // 21,22 training load day/week
        u8(0); u8(0); u8(0); u8(0) // 23,24,25,26
        u16(0)         // 27 vitality current
        u8(0); u8(0)   // 28,29 reserved
        u16(0); u16(0) // 30,31 reserved

        var full = Data([0x64, 0x00, 0x00, 0x00, 0x08, 0x05, 0x00]) // fileId: ts=100, tz=8, version=5, flags=0
        full.append(0) // padding
        full.append(contentsOf: header)
        full.append(body)
        return full
    }

    private let fileId = XiaomiProto.DecodedActivityFileId(
        timestamp: Date(timeIntervalSince1970: 100), timezoneBlocks: 8, version: 5, flags: 0
    )

    func testDecodesKnownFields() {
        let record = DailySummaryParser.parse(fileId: fileId, bytes: makeBody())
        XCTAssertEqual(record?.steps, 8000)
        XCTAssertEqual(record?.activeCalories, 300)
        XCTAssertEqual(record?.totalCalories, 1800)
        XCTAssertEqual(record?.restingHeartRate, 58)
        XCTAssertEqual(record?.maxHeartRate, 142)
        XCTAssertEqual(record?.maxHeartRateTimestamp, Date(timeIntervalSince1970: 1700000100))
        XCTAssertEqual(record?.minHeartRate, 50)
        XCTAssertEqual(record?.avgHeartRate, 72)
    }

    func testInvalidBitDropsField() {
        var bits = Array(repeating: true, count: 32)
        bits[3] = false // restingHR slot marked invalid
        let record = DailySummaryParser.parse(fileId: fileId, bytes: makeBody(headerBits: bits))
        XCTAssertNil(record?.restingHeartRate)
        XCTAssertEqual(record?.steps, 8000) // other slots unaffected
    }

    func testUnsupportedVersionReturnsNil() {
        let v4 = XiaomiProto.DecodedActivityFileId(timestamp: Date(), timezoneBlocks: 0, version: 4, flags: 0)
        XCTAssertNil(DailySummaryParser.parse(fileId: v4, bytes: makeBody()))
    }

    func testTruncatedBodyReturnsNilNotCrash() {
        XCTAssertNil(DailySummaryParser.parse(fileId: fileId, bytes: Data([0, 1, 2])))
    }
}
