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
// Daily-summary body decoder (docs/PROTOCOL.md §6.3), version 5 only
// ("Mi Band 10 and later" -- DailySummaryParser.java:140). v3/v4 (21-slot,
// 3-byte header) are older bands, out of scope. Slot layout/order matches
// DailySummaryParser.java's SLOTS table verbatim, including the reserved
// slots -- they must still be consumed to keep the cursor aligned even
// though this app doesn't store their values.

import Foundation

struct DailySummaryRecord: Codable, Equatable {
    var date: Date // local day this record covers, per fileId.timezoneBlocks
    var steps: Int
    var activeCalories: Int
    var totalCalories: Int
    var restingHeartRate: Int?
    var minHeartRate: Int?
    var minHeartRateTimestamp: Date?
    var maxHeartRate: Int?
    var maxHeartRateTimestamp: Date?
    var avgHeartRate: Int?
}

enum DailySummaryParser {
    private static func validBit(_ header: [UInt8], _ i: Int) -> Bool {
        (header[i / 8] & (1 << (7 - (i % 8)))) != 0
    }

    static func parse(fileId: XiaomiProto.DecodedActivityFileId, bytes: Data) -> DailySummaryRecord? {
        guard fileId.version == 5 else { return nil }
        let raw = [UInt8](bytes)
        guard raw.count >= 7 + 1 + 4 else { return nil } // fileId + padding + header, at minimum

        var offset = 7 // skip the 7-byte fileId prefix (§6.2 step 5)
        offset += 1    // padding byte, expected 0 -- not fatal if not, matches Java's warn-and-continue
        let header = Array(raw[offset..<offset + 4])
        offset += 4

        func hasMore(_ n: Int) -> Bool { offset + n <= raw.count }
        func u8() -> UInt8 { defer { offset += 1 }; return raw[offset] }
        func u16() -> UInt16 { defer { offset += 2 }; return UInt16(raw[offset]) | UInt16(raw[offset + 1]) << 8 }
        func u32() -> UInt32 {
            defer { offset += 4 }
            return UInt32(raw[offset]) | UInt32(raw[offset + 1]) << 8
                | UInt32(raw[offset + 2]) << 16 | UInt32(raw[offset + 3]) << 24
        }

        var steps = 0, activeCalories = 0, totalCalories = 0
        var restingHR: Int?
        var minHR: Int?, minHRTs: Date?
        var maxHR: Int?, maxHRTs: Date?
        var avgHR: Int?

        for slot in 0..<32 {
            let valid = validBit(header, slot)
            switch slot {
            case 0: guard hasMore(4) else { return nil }; let v = Int(u32()); if valid { steps = v }
            case 1: guard hasMore(2) else { return nil }; let v = Int(u16()); if valid { activeCalories = v }
            case 2: guard hasMore(1) else { return nil }; _ = u8() // reserved
            case 3: guard hasMore(1) else { return nil }; let v = Int(u8()); if valid { restingHR = v }
            case 4: guard hasMore(1) else { return nil }; let v = Int(u8()); if valid { maxHR = v }
            case 5: guard hasMore(4) else { return nil }; let v = u32(); if valid { maxHRTs = Date(timeIntervalSince1970: TimeInterval(v)) }
            case 6: guard hasMore(1) else { return nil }; let v = Int(u8()); if valid { minHR = v }
            case 7: guard hasMore(4) else { return nil }; let v = u32(); if valid { minHRTs = Date(timeIntervalSince1970: TimeInterval(v)) }
            case 8: guard hasMore(1) else { return nil }; let v = Int(u8()); if valid { avgHR = v }
            case 9, 10, 11: guard hasMore(1) else { return nil }; _ = u8() // stress avg/max/min -- not synced (v1 scope)
            case 12: guard hasMore(3) else { return nil }; offset += 3 // standing bitmap -- not synced
            case 13: guard hasMore(2) else { return nil }; let v = Int(u16()); if valid { totalCalories = v }
            case 14: guard hasMore(2) else { return nil }; _ = u16() // recovery hours
            case 15: guard hasMore(1) else { return nil }; _ = u8() // reserved
            case 16: guard hasMore(1) else { return nil }; _ = u8() // SpO2 max
            case 17: guard hasMore(4) else { return nil }; _ = u32() // SpO2 max ts
            case 18: guard hasMore(1) else { return nil }; _ = u8() // SpO2 min
            case 19: guard hasMore(4) else { return nil }; _ = u32() // SpO2 min ts
            case 20: guard hasMore(1) else { return nil }; _ = u8() // SpO2 avg
            case 21, 22: guard hasMore(2) else { return nil }; _ = u16() // training load day/week
            case 23, 24, 25, 26: guard hasMore(1) else { return nil }; _ = u8() // training load level, vitality light/mod/high
            case 27: guard hasMore(2) else { return nil }; _ = u16() // vitality current
            case 28, 29: guard hasMore(1) else { return nil }; _ = u8() // reserved
            case 30, 31: guard hasMore(2) else { return nil }; _ = u16() // reserved
            default: break
            }
        }

        // Local calendar day this file covers: shift by the reported
        // timezone offset (15-min blocks) before truncating to a day
        // boundary, so the dedup key in LocalStore (Task 5) lines up with
        // wall-clock date, not raw UTC date.
        let shifted = fileId.timestamp.addingTimeInterval(TimeInterval(fileId.timezoneBlocks) * 15 * 60)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let dayStart = utcCalendar.startOfDay(for: shifted)

        return DailySummaryRecord(
            date: dayStart,
            steps: steps, activeCalories: activeCalories, totalCalories: totalCalories,
            restingHeartRate: restingHR,
            minHeartRate: minHR, minHeartRateTimestamp: minHRTs,
            maxHeartRate: maxHR, maxHeartRateTimestamp: maxHRTs,
            avgHeartRate: avgHR
        )
    }
}
