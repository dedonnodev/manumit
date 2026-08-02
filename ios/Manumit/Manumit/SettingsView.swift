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
// Auth key re-entry, "forget device", fixture export, and the raw
// session log -- the leftover debug affordances from the old
// ContentView (deleted alongside this file), relocated here.
// CLAUDE.md's instrumentation rule (fixture logging) stays mandatory;
// it's just not the home-screen UI anymore.

import SwiftUI

private let keychainAccount = "auth-key"

struct SettingsView: View {
    @EnvironmentObject private var session: BandSession
    @State private var authKeyHex = KeychainStore.load(account: keychainAccount) ?? ""

    var body: some View {
        Form {
            Section("Auth key") {
                SecureField("MIBAND_AUTH_KEY", text: $authKeyHex)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Save") {
                    KeychainStore.save(authKeyHex, account: keychainAccount)
                }
                .disabled(authKeyHex.count != 32)
            }

            Section("Device") {
                Button("Forget this band", role: .destructive) {
                    KeychainStore.delete(account: BandSession.savedPeripheralAccount)
                }
            }

            if let fixtureURL = session.fixtureURL {
                Section("Fixture") {
                    ShareLink("Export fixture (\(fixtureURL.lastPathComponent))", item: fixtureURL)
                }
            }

            Section("Log") {
                ScrollView {
                    Text(session.log.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 300)
            }
        }
    }
}
