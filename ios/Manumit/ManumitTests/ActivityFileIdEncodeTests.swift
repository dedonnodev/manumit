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

final class ActivityFileIdEncodeTests: XCTestCase {
    func testEncodeIsInverseOfDecode() {
        // Same synthetic bytes XiaomiProto.selfTest() already uses for decode.
        let raw = Data([0x64, 0x00, 0x00, 0x00, 0x04, 0x06, 0x00]) // ts=100, tz=4, version=6, flags=0x00
        let decoded = XiaomiProto.decodeActivityFileIds(fromHealth: {
            var w = ProtoWriter(); w.putBytes(2, raw); return w.data
        }())!
        XCTAssertEqual(decoded[0].encode(), raw)
    }

    func testPastRequestIsBareTypeSubtype() {
        // Command{type=8, subtype=2}, no health field at all
        // (XiaomiHealthService.java:816-824, fetchRecordedDataPast).
        let built = XiaomiProto.commandTypeSubtypeOnly(type: 8, subtype: 2)
        XCTAssertEqual(built, Data([0x08, 0x08, 0x10, 0x02]))
    }
}
