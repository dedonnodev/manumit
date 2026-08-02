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

import SwiftUI
import HealthKit

struct MainTabView: View {
    @StateObject private var session = BandSession()
    @StateObject private var systemCommands: SystemCommandService
    private let healthStore = HKHealthStore()

    init() {
        let session = BandSession()
        _session = StateObject(wrappedValue: session)
        _systemCommands = StateObject(wrappedValue: SystemCommandService(session: session))
    }

    var body: some View {
        TabView {
            DashboardView(healthStore: healthStore)
                .environmentObject(session)
                .tabItem { Label("Dashboard", systemImage: "gauge") }
            SystemView()
                .environmentObject(systemCommands)
                .environmentObject(session)
                .tabItem { Label("System", systemImage: "app.badge") }
            // Task 11 adds a Settings tab here.
        }
    }
}
