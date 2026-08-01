# Copyright (C) 2026 miband contributors
#
# This file is part of miband.
#
# miband is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# miband is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
"""Bluetooth Classic RFCOMM transport (see docs/PROTOCOL.md §0-1).

connect()/send()/recv() (M3) not implemented yet; scan() (M1) is. Abstract
base kept thin and off-device-testable, per CLAUDE.md.
"""

import asyncio
import re
import sys
from abc import ABC, abstractmethod
from dataclasses import dataclass

DEVICE_NAME_RE = re.compile(r"^Xiaomi Smart Band 10 [0-9A-F]{4}$")

# Bluetooth-Classic Association Endpoint Provider protocol id, used in
# Microsoft's own device-watcher samples to filter DeviceInformation to
# classic-BT devices. [from WinRT platform knowledge, not from Gadgetbridge
# source, untested] -- the first thing to check if `scan` finds nothing.
_AEP_BLUETOOTH_SELECTOR = (
    'System.Devices.Aep.ProtocolId:="{e0cbf06c-cd8b-4647-bb8a-263b43f0f974}"'
)


@dataclass
class DiscoveredDevice:
    name: str
    address: str  # "AA:BB:CC:DD:EE:FF"


async def scan(timeout_seconds: float = 10.0) -> list[DiscoveredDevice]:
    """Discover nearby classic-Bluetooth devices (Windows only).

    Uses WinRT device enumeration directly, not bleak: bleak is BLE-only and
    cannot see this device (docs/PROTOCOL.md §0). [from WinRT platform
    knowledge, untested]: confirm on real hardware that the AEP selector
    above actually surfaces the band and that `BluetoothDevice.from_id_async`
    resolves a usable address.
    """
    if sys.platform != "win32":
        raise RuntimeError(
            "Bluetooth is only available on native Windows (see CLAUDE.md); "
            "this can't run under WSL/Linux."
        )

    from winrt.windows.devices.bluetooth import BluetoothDevice
    from winrt.windows.devices.enumeration import (
        DeviceInformation,
        DeviceInformationKind,
    )

    found: dict[str, str] = {}
    watcher = DeviceInformation.create_watcher(
        _AEP_BLUETOOTH_SELECTOR, None, DeviceInformationKind.ASSOCIATION_ENDPOINT
    )
    watcher.add_added(lambda _watcher, info: found.setdefault(info.id, info.name))
    watcher.start()
    try:
        await asyncio.sleep(timeout_seconds)
    finally:
        watcher.stop()

    devices = []
    for device_id, name in found.items():
        if not name:
            continue
        bt_device = await BluetoothDevice.from_id_async(device_id)
        if bt_device is None:
            continue
        addr = bt_device.bluetooth_address
        mac = ":".join(f"{(addr >> (8 * i)) & 0xFF:02X}" for i in reversed(range(6)))
        devices.append(DiscoveredDevice(name=name, address=mac))
    return devices


class Transport(ABC):
    @abstractmethod
    def connect(self) -> None: ...

    @abstractmethod
    def send(self, data: bytes) -> None: ...

    @abstractmethod
    def recv(self) -> bytes: ...

    @abstractmethod
    def close(self) -> None: ...
