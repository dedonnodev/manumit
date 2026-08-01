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
// Two one-shot diagnostics for whether the Band 10 is reachable from a
// non-jailbroken iOS app at all:
//
// 1. EAAccessoryManager.connectedAccessories -- non-empty = MFi-registered,
//    RFCOMM/SPP reachable via ExternalAccessory. Empty is NOT conclusive by
//    itself: this property is filtered by this app's declared protocol
//    strings in Info.plist (none declared here), so empty means either
//    "not MFi" or "MFi but wrong/no protocol string".
// 2. CBCentralManager BLE scan -- unlike EAAccessoryManager this has no MFi
//    gate, CoreBluetooth can see any advertising BLE peripheral. If the
//    Band 10 shows up here, it has a BLE side separate from the classic-BT
//    RFCOMM interface Gadgetbridge uses on Android (docs/PROTOCOL.md §0),
//    and that's the transport an iOS app would have to speak instead.

import SwiftUI
import ExternalAccessory
import CoreBluetooth

struct ContentView: View {
    @State private var mfiOutput = "Tap per controllare."
    @StateObject private var bleScanner = BLEScanner()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MFi (ExternalAccessory)").font(.headline)
            ScrollView {
                Text(mfiOutput)
                    .font(.system(.caption, design: .monospaced))
            }
            .frame(maxHeight: 120)
            Button("Check connected accessories") { checkMFi() }

            Divider()

            Text("BLE scan (CoreBluetooth)").font(.headline)
            ScrollView {
                Text(bleScanner.output)
                    .font(.system(.caption, design: .monospaced))
            }
            Button(bleScanner.isScanning ? "Stop scan" : "Start BLE scan") {
                bleScanner.toggle()
            }
        }
        .padding()
        .onAppear(perform: checkMFi)
    }

    func checkMFi() {
        let accessories = EAAccessoryManager.shared().connectedAccessories
        if accessories.isEmpty {
            mfiOutput = "connectedAccessories: EMPTY\n(0 accessori visibili come MFi)"
            return
        }
        mfiOutput = accessories.map { acc in
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

final class BLEScanner: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published var output = "Tap per avviare lo scan."
    @Published var isScanning = false

    private var manager: CBCentralManager?
    private var found: [UUID: (rssi: Int, line: String)] = [:]

    func toggle() {
        if isScanning {
            manager?.stopScan()
            isScanning = false
            return
        }
        found = [:]
        output = "In attesa del radio Bluetooth..."
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            output = "Bluetooth non pronto: state=\(central.state.rawValue)"
            return
        }
        found = [:]
        central.scanForPeripherals(withServices: nil, options: nil)
        isScanning = true
        output = "Scanning..."
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "(no name)"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map(\.uuidString).joined(separator: ",") ?? "-"

        var manufacturer = "-"
        if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count >= 2 {
            // First 2 bytes = Bluetooth SIG company ID, little-endian; rest is
            // vendor-specific payload. Cross-reference the ID against
            // https://www.bluetooth.com/specifications/assigned-numbers/company-identifiers/
            // -- not hardcoding a vendor name here since we haven't verified it.
            let companyId = UInt16(data[1]) << 8 | UInt16(data[0])
            let hex = data.map { String(format: "%02X", $0) }.joined()
            manufacturer = String(format: "companyId=0x%04X data=%@", companyId, hex)
        }

        let rssi = RSSI.intValue
        found[peripheral.identifier] = (
            rssi: rssi,
            line: "\(name)  rssi=\(rssi)  id=\(peripheral.identifier)  services=\(services)  mfgData=\(manufacturer)"
        )
        output = found.values
            .sorted { $0.rssi > $1.rssi }
            .map(\.line)
            .joined(separator: "\n")
    }
}
