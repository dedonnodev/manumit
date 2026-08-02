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
// Hide/show built-in apps (System.displayItems) and list/delete
// QuickApps (Rpk) -- specific, mapped actions, not a raw command console
// (spec non-goal).

import SwiftUI

struct SystemView: View {
    @EnvironmentObject private var commands: SystemCommandService
    @EnvironmentObject private var session: BandSession

    var body: some View {
        List {
            Section("Apps & widgets on the band") {
                ForEach(commands.displayItems, id: \.code) { item in
                    Toggle(item.name.isEmpty ? item.code : item.name, isOn: Binding(
                        get: { !item.disabled },
                        set: { enabled in
                            var updated = commands.displayItems
                            guard let idx = updated.firstIndex(where: { $0.code == item.code }) else { return }
                            updated[idx].disabled = !enabled
                            commands.setDisplayItems(updated)
                        }
                    ))
                }
            }
            Section("Installed QuickApps") {
                ForEach(commands.installedApps, id: \.id) { app in
                    HStack {
                        Text(app.name.isEmpty ? app.id : app.name)
                        Spacer()
                        Button("Delete", role: .destructive) {
                            commands.deleteRpk(id: app.id, sha: app.sha)
                        }
                    }
                }
            }
        }
        .onAppear {
            guard session.state == .authenticated else { return }
            commands.getDisplayItems()
            commands.getRpkList()
        }
    }
}
