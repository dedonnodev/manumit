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
// One-shot diagnostic: is the Band 10 visible to EAAccessoryManager after
// pairing via Settings? Non-empty result = MFi-visible, RFCOMM reachable
// from a third-party app. Empty result alone doesn't rule that out --
// connectedAccessories is filtered by this app's declared protocol strings
// in Info.plist (none declared here), so empty just means "try again once
// we know the protocol string" as well as "not MFi at all".

import SwiftUI
import ExternalAccessory

struct ContentView: View {
    @State private var output = "Tap per controllare."

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                Text(output)
                    .font(.system(.body, design: .monospaced))
                    .padding()
            }
            Button("Check connected accessories") {
                check()
            }
        }
        .onAppear(perform: check)
    }

    func check() {
        let accessories = EAAccessoryManager.shared().connectedAccessories
        if accessories.isEmpty {
            output = "connectedAccessories: EMPTY\n(0 accessori visibili come MFi)"
            return
        }
        output = accessories.map { acc in
            """
            name: \(acc.name)
            manufacturer: \(acc.manufacturer)
            modelNumber: \(acc.modelNumber)
            protocolStrings: \(acc.protocolStrings)
            connectionID: \(acc.connectionID)
            """
        }.joined(separator: "\n---\n")
    }
}
