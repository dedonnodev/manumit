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

@main
struct ManumitApp: App {
    @State private var onboarded = KeychainStore.load(account: keychainAccount) != nil

    init() {
        #if DEBUG
        SppV2Codec.selfTest()
        XiaomiProto.selfTest()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            if onboarded {
                Text("Main app lands in Task 9") // Task 9 Step 4 replaces this with MainTabView()
            } else {
                OnboardingView { onboarded = true }
            }
        }
    }
}
