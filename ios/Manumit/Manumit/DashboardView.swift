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
// Connection state, battery/device metadata (M4), and HealthKit sync
// status. Replaces the raw-log-as-primary-view from the old ContentView
// (log itself moves to Settings, Task 11).

import SwiftUI
import HealthKit

struct DashboardView: View {
    @EnvironmentObject private var session: BandSession
    let healthStore: HKHealthStore

    @State private var syncedCount = 0
    @State private var lastSyncedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manumit").font(.largeTitle.bold())
            Text("State: \(session.state.label)").font(.headline)

            if case .failed(let reason) = session.state {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            Divider()
            Text("Sync").font(.headline)
            if let lastSyncedAt {
                Text("Last synced \(lastSyncedAt.formatted()), \(syncedCount) day(s) written")
            } else {
                Text("No sync yet")
            }

            Spacer()
        }
        .padding()
        .onAppear {
            if BandSession.hasSavedPeripheral || true { // scanning-if-not-saved is BandSession's own concern
                // auth key is guaranteed present by onboarding (Task 8) before this view exists
            }
            session.onDailySummaryParsed = { record in
                guard LocalStore.shared.upsert(record) else { return }
                HealthKitStore.save(record, store: healthStore) { success in
                    if success {
                        syncedCount += 1
                        lastSyncedAt = Date()
                    }
                }
            }
            if let key = KeychainStore.load(account: "auth-key"), session.state == .idle {
                session.start(secretKeyHex: key)
            }
        }
    }
}
