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
import HealthKit
@testable import Manumit

final class HealthKitMappingTests: XCTestCase {
    private func record() -> DailySummaryRecord {
        DailySummaryRecord(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            steps: 8000, activeCalories: 300, totalCalories: 1800,
            restingHeartRate: 58,
            minHeartRate: 50, minHeartRateTimestamp: Date(timeIntervalSince1970: 1_700_000_000),
            maxHeartRate: 142, maxHeartRateTimestamp: Date(timeIntervalSince1970: 1_700_000_100),
            avgHeartRate: 72
        )
    }

    func testMapsStepsAndCalories() {
        let samples = HealthKitStore.makeSamples(for: record())
        let steps = samples.first { $0.quantityType == HKObjectType.quantityType(forIdentifier: .stepCount)! }
        XCTAssertEqual(steps?.quantity.doubleValue(for: .count()), 8000)

        let active = samples.first { $0.quantityType == HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)! }
        XCTAssertEqual(active?.quantity.doubleValue(for: .kilocalorie()), 300)

        // basal = total - active
        let basal = samples.first { $0.quantityType == HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)! }
        XCTAssertEqual(basal?.quantity.doubleValue(for: .kilocalorie()), 1500)
    }

    func testMapsHeartRateSamplesAtTheirOwnTimestamps() {
        let samples = HealthKitStore.makeSamples(for: record())
        let hrType = HKObjectType.quantityType(forIdentifier: .heartRate)!
        let hrSamples = samples.filter { $0.quantityType == hrType }
        XCTAssertEqual(hrSamples.count, 3) // min, max, avg

        let max = hrSamples.first { $0.quantity.doubleValue(for: .count().unitDivided(by: .minute())) == 142 }
        XCTAssertEqual(max?.startDate, Date(timeIntervalSince1970: 1_700_000_100))

        let resting = samples.first { $0.quantityType == HKObjectType.quantityType(forIdentifier: .restingHeartRate)! }
        XCTAssertEqual(resting?.quantity.doubleValue(for: .count().unitDivided(by: .minute())), 58)
    }

    func testZeroBasalOmitted() {
        var r = record()
        r.totalCalories = r.activeCalories // basal would be 0
        let samples = HealthKitStore.makeSamples(for: r)
        XCTAssertNil(samples.first { $0.quantityType == HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)! })
    }
}
