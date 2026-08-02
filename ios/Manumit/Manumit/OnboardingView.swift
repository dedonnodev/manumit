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

private let keychainAccount = "auth-key"

struct OnboardingView: View {
    let onDone: () -> Void

    @State private var authKeyHex = ""
    @State private var step: Step = .authKey

    enum Step { case authKey, healthKit }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case .authKey:
                Text("Connect your Band 10").font(.largeTitle.bold())
                Text("Auth key (32 hex chars, from `uv run miband auth-key`)").font(.caption)
                SecureField("MIBAND_AUTH_KEY", text: $authKeyHex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Continue") {
                    KeychainStore.save(authKeyHex, account: keychainAccount)
                    step = .healthKit
                }
                .disabled(authKeyHex.count != 32)
            case .healthKit:
                Text("Sync to Apple Health").font(.largeTitle.bold())
                Text("Manumit writes steps, calories, and heart rate from your band to the Health app. It never reads anything back.")
                    .font(.body)
                Button("Allow") {
                    HealthKitStore.requestAuthorization(store: HKHealthStore()) { _ in onDone() }
                }
                Button("Not now") { onDone() }
            }
            Spacer()
        }
        .padding()
    }
}
