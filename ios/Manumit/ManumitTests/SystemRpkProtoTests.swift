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

import XCTest
@testable import Manumit

final class SystemRpkProtoTests: XCTestCase {
    func testDisplayItemsGetIsBareTypeSubtype() {
        // CMD_DISPLAY_ITEMS_GET=29 (XiaomiSystemService.java:90)
        XCTAssertEqual(XiaomiProto.commandTypeSubtypeOnly(type: 2, subtype: 29), Data([0x08, 0x02, 0x10, 0x1D]))
    }

    func testDisplayItemsSetRoundTrip() {
        let items = [
            XiaomiProto.DecodedDisplayItem(code: "weather", name: "Weather", disabled: false, isSettings: 0, inMoreSection: false),
            XiaomiProto.DecodedDisplayItem(code: "compass", name: "Compass", disabled: true, isSettings: 0, inMoreSection: true),
        ]
        let built = XiaomiProto.commandSetDisplayItems(items)
        let decoded = XiaomiProto.decodeCommand(built)
        XCTAssertEqual(decoded.type, 2)
        XCTAssertEqual(decoded.subtype, 30) // CMD_DISPLAY_ITEMS_SET
        guard let systemBytes = decoded.systemBytes, let roundTripped = XiaomiProto.decodeDisplayItems(fromSystem: systemBytes) else {
            return XCTFail("should decode back")
        }
        XCTAssertEqual(roundTripped.count, 2)
        XCTAssertEqual(roundTripped[1].code, "compass")
        XCTAssertTrue(roundTripped[1].disabled)
        XCTAssertTrue(roundTripped[1].inMoreSection)
    }

    func testRpkListIsBareTypeSubtype() {
        XCTAssertEqual(XiaomiProto.commandRpkList(), Data([0x08, 0x14, 0x10, 0x00]))
    }

    func testRpkListDecodesResponse() {
        var info1 = ProtoWriter(); info1.putString(1, "com.xiaomi.smarthome.watch"); info1.putString(5, "Mi Home")
        var list = ProtoWriter(); list.putMessage(1, info1.data)
        var rpk = ProtoWriter(); rpk.putMessage(1, list.data)
        var cmd = ProtoWriter(); cmd.putVarint(1, 20); cmd.putVarint(2, 0); cmd.putMessage(22, rpk.data)

        let decoded = XiaomiProto.decodeCommand(cmd.data)
        guard let rpkBytes = decoded.rpkBytes, let apps = XiaomiProto.decodeRpkList(fromRpk: rpkBytes) else {
            return XCTFail("should decode rpk list")
        }
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].id, "com.xiaomi.smarthome.watch")
        XCTAssertEqual(apps[0].name, "Mi Home")
    }

    func testDeleteRpkEncodesIdAndSha() {
        let sha = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let built = XiaomiProto.commandDeleteRpk(id: "com.example.app", sha: sha)
        let decoded = XiaomiProto.decodeCommand(built)
        XCTAssertEqual(decoded.type, 20)
        XCTAssertEqual(decoded.subtype, 3) // CMD_RPK_DELETE
        XCTAssertNotNil(decoded.rpkBytes)
    }
}
