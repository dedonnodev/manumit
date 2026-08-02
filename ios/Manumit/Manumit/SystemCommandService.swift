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
// System tab actions: hide/show built-in apps (System.displayItems) and
// list/delete QuickApps (Rpk). Specific, mapped commands -- not a raw/
// generic console (spec non-goal).

import Foundation
import Combine

final class SystemCommandService: ObservableObject {
    @Published private(set) var displayItems: [XiaomiProto.DecodedDisplayItem] = []
    @Published private(set) var installedApps: [XiaomiProto.DecodedRpkInfo] = []

    private let session: BandSession
    private var previousHandler: ((XiaomiProto.DecodedCommand) -> Void)?

    init(session: BandSession) {
        self.session = session
        self.previousHandler = session.onEncryptedCommand
        session.onEncryptedCommand = { [weak self] command in
            self?.previousHandler?(command)
            self?.handle(command)
        }
    }

    private func handle(_ command: XiaomiProto.DecodedCommand) {
        switch (command.type, command.subtype) {
        case (2, 29): // CMD_DISPLAY_ITEMS_GET response
            if let systemBytes = command.systemBytes, let items = XiaomiProto.decodeDisplayItems(fromSystem: systemBytes) {
                DispatchQueue.main.async { self.displayItems = items }
            }
        case (20, 0): // CMD_RPK_LIST response
            if let rpkBytes = command.rpkBytes, let apps = XiaomiProto.decodeRpkList(fromRpk: rpkBytes) {
                DispatchQueue.main.async { self.installedApps = apps }
            }
        default:
            break
        }
    }

    func getDisplayItems() {
        session.sendEncryptedCommand(XiaomiProto.commandTypeSubtypeOnly(type: 2, subtype: 29))
    }

    func setDisplayItems(_ items: [XiaomiProto.DecodedDisplayItem]) {
        session.sendEncryptedCommand(XiaomiProto.commandSetDisplayItems(items))
        displayItems = items // optimistic local update -- band sends no confirming response
    }

    func getRpkList() {
        session.sendEncryptedCommand(XiaomiProto.commandRpkList())
    }

    func deleteRpk(id: String, sha: Data) {
        session.sendEncryptedCommand(XiaomiProto.commandDeleteRpk(id: id, sha: sha))
        getRpkList() // band sends no delete response -- re-request immediately (XiaomiRpkService.java:104-124)
    }
}
