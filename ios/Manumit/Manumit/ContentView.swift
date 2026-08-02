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

private let keychainAccount = "auth-key"

struct ContentView: View {
    @StateObject private var session = BandSession()
    // Loaded in onAppear, not here -- SecureField has a known SwiftUI bug
    // where text set on a @State var before the field's first layout pass
    // doesn't render (the dots just don't show up), even though the bound
    // value and everything downstream of it (this auto-connect check
    // included) is correct. Assigning after the view has appeared works
    // around it.
    @State private var authKeyHex: String = ""
    @State private var keychainSaveConfirmedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manumit").font(.largeTitle.bold())
            Text("M4: encrypted round-trip against the Band 10 (docs/PROTOCOL.md §4.2)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("Auth key (32 hex chars, from `uv run miband auth-key`)").font(.caption)
            SecureField("MIBAND_AUTH_KEY", text: $authKeyHex)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            HStack {
                Button("Save to Keychain") {
                    KeychainStore.save(authKeyHex, account: keychainAccount)
                    keychainSaveConfirmedAt = Date()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        keychainSaveConfirmedAt = nil
                    }
                }
                .disabled(authKeyHex.count != 32)
                if keychainSaveConfirmedAt != nil {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
            .animation(.default, value: keychainSaveConfirmedAt)

            Divider()

            Text("State: \(session.state.label)").font(.headline)
            Button("Connect & Authenticate") {
                session.start(secretKeyHex: authKeyHex)
            }
            .disabled(authKeyHex.count != 32)
            if session.state == .scanning {
                Text("Stuck scanning? Trigger a sync from Mi Fitness first -- the Band's advertising window is narrow and tied to that sync (docs/PROTOCOL.md §0a).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Log").font(.headline)
            ScrollView {
                Text(session.log.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let fixtureURL = session.fixtureURL {
                ShareLink("Export fixture (\(fixtureURL.lastPathComponent))", item: fixtureURL)
            }

            Spacer()
        }
        .padding()
        .onAppear {
            authKeyHex = KeychainStore.load(account: keychainAccount) ?? authKeyHex
            if authKeyHex.count == 32, BandSession.hasSavedPeripheral, session.state == .idle {
                session.start(secretKeyHex: authKeyHex)
            }
        }
    }
}
