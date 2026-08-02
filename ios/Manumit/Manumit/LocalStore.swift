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
// Local storage half of CLAUDE.md's end goal ("stores data locally, writes
// it to Apple Health"). Not SwiftData -- deployment target is iOS 16,
// SwiftData needs 17+. A Codable dictionary in one JSON file is enough for
// "one record per day, upsert by day."

import Foundation

final class LocalStore {
    private let fileURL: URL
    private var records: [String: DailySummaryRecord]

    static let shared = LocalStore(fileURL: {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("daily-summaries.json")
    }())

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: DailySummaryRecord].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func key(for record: DailySummaryRecord) -> String {
        Self.keyFormatter.string(from: record.date)
    }

    /// Returns true if this record is new or different from what was
    /// stored -- the caller (BandSession's sync) uses this to decide
    /// whether a HealthKit write is needed, so re-syncing an unchanged day
    /// doesn't create duplicate samples.
    @discardableResult
    func upsert(_ record: DailySummaryRecord) -> Bool {
        let k = key(for: record)
        guard records[k] != record else { return false }
        records[k] = record
        persist()
        return true
    }

    func all() -> [DailySummaryRecord] {
        Array(records.values)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
