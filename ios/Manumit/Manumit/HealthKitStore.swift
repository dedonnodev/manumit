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
// One-way writer: DailySummaryRecord -> HealthKit. Uses the classic
// HKObjectType.quantityType(forIdentifier:) API, not the iOS 18
// HKQuantityType(.stepCount) sugar -- deployment target is iOS 16.

import Foundation
import HealthKit

enum HealthKitStore {
    static let stepType = HKObjectType.quantityType(forIdentifier: .stepCount)!
    static let activeEnergyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
    static let basalEnergyType = HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)!
    static let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)!
    static let restingHeartRateType = HKObjectType.quantityType(forIdentifier: .restingHeartRate)!

    static func requestAuthorization(store: HKHealthStore, completion: @escaping (Bool) -> Void) {
        let types: Set<HKSampleType> = [stepType, activeEnergyType, basalEnergyType, heartRateType, restingHeartRateType]
        store.requestAuthorization(toShare: types, read: []) { success, _ in
            DispatchQueue.main.async { completion(success) }
        }
    }

    /// Pure mapping, no HealthKit I/O -- unit-testable without authorization.
    /// `totalCalories - activeCalories` is written as basal/resting energy
    /// (Gadgetbridge's daily-summary has no separate "resting calories"
    /// field; `calories` (slot 13) is the total, `activeCalories` (slot 1)
    /// the active portion -- the difference is the resting/basal share).
    static func makeSamples(for record: DailySummaryRecord) -> [HKQuantitySample] {
        var samples: [HKQuantitySample] = []
        let dayStart = record.date
        let dayEnd = record.date.addingTimeInterval(24 * 3600)

        if record.steps > 0 {
            samples.append(HKQuantitySample(
                type: stepType,
                quantity: HKQuantity(unit: .count(), doubleValue: Double(record.steps)),
                start: dayStart, end: dayEnd
            ))
        }
        if record.activeCalories > 0 {
            samples.append(HKQuantitySample(
                type: activeEnergyType,
                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: Double(record.activeCalories)),
                start: dayStart, end: dayEnd
            ))
        }
        let basal = record.totalCalories - record.activeCalories
        if basal > 0 {
            samples.append(HKQuantitySample(
                type: basalEnergyType,
                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: Double(basal)),
                start: dayStart, end: dayEnd
            ))
        }
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        if let resting = record.restingHeartRate {
            samples.append(HKQuantitySample(
                type: restingHeartRateType,
                quantity: HKQuantity(unit: bpmUnit, doubleValue: Double(resting)),
                start: dayStart, end: dayEnd
            ))
        }
        if let max = record.maxHeartRate, let ts = record.maxHeartRateTimestamp {
            samples.append(HKQuantitySample(type: heartRateType, quantity: HKQuantity(unit: bpmUnit, doubleValue: Double(max)), start: ts, end: ts))
        }
        if let min = record.minHeartRate, let ts = record.minHeartRateTimestamp {
            samples.append(HKQuantitySample(type: heartRateType, quantity: HKQuantity(unit: bpmUnit, doubleValue: Double(min)), start: ts, end: ts))
        }
        if let avg = record.avgHeartRate {
            let noon = dayStart.addingTimeInterval(12 * 3600) // no per-sample timestamp for the daily average
            samples.append(HKQuantitySample(type: heartRateType, quantity: HKQuantity(unit: bpmUnit, doubleValue: Double(avg)), start: noon, end: noon))
        }
        return samples
    }

    static func save(_ record: DailySummaryRecord, store: HKHealthStore, completion: @escaping (Bool) -> Void) {
        let samples = makeSamples(for: record)
        guard !samples.isEmpty else { completion(true); return }
        store.save(samples) { success, _ in
            DispatchQueue.main.async { completion(success) }
        }
    }
}
