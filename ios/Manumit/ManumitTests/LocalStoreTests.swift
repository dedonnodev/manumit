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

final class LocalStoreTests: XCTestCase {
    private func tempStore() -> LocalStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        return LocalStore(fileURL: url)
    }

    private func record(day: Int, steps: Int) -> DailySummaryRecord {
        DailySummaryRecord(
            date: Date(timeIntervalSince1970: TimeInterval(day * 86400)),
            steps: steps, activeCalories: 0, totalCalories: 0,
            restingHeartRate: nil, minHeartRate: nil, minHeartRateTimestamp: nil,
            maxHeartRate: nil, maxHeartRateTimestamp: nil, avgHeartRate: nil
        )
    }

    func testUpsertNewRecordReturnsTrue() {
        let store = tempStore()
        XCTAssertTrue(store.upsert(record(day: 1, steps: 100)))
        XCTAssertEqual(store.all().count, 1)
    }

    func testUpsertUnchangedRecordReturnsFalse() {
        let store = tempStore()
        _ = store.upsert(record(day: 1, steps: 100))
        XCTAssertFalse(store.upsert(record(day: 1, steps: 100)))
        XCTAssertEqual(store.all().count, 1)
    }

    func testUpsertChangedRecordReturnsTrueAndReplaces() {
        let store = tempStore()
        _ = store.upsert(record(day: 1, steps: 100))
        XCTAssertTrue(store.upsert(record(day: 1, steps: 200)))
        XCTAssertEqual(store.all().first?.steps, 200)
        XCTAssertEqual(store.all().count, 1)
    }

    func testPersistsAcrossInstances() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        _ = LocalStore(fileURL: url).upsert(record(day: 1, steps: 100))
        let reopened = LocalStore(fileURL: url)
        XCTAssertEqual(reopened.all().count, 1)
        XCTAssertEqual(reopened.all().first?.steps, 100)
    }
}
