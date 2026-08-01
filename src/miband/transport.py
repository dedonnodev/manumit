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

# Empty AQS filter = every nearby Association Endpoint (classic BT and BLE),
# unfiltered. Was previously restricted to the classic-BT protocol id
# (e0cbf06c-cd8b-4647-bb8a-263b43f0f974) but that silently dropped the Band
# 10 on real hardware -- confirmed via `miband scan` finding nothing while
# Windows' own pairing UI found it. Filtering by name (DEVICE_NAME_RE) at
# display time instead.
_AEP_BLUETOOTH_SELECTOR = ""

# HRESULT 0x800710DF ("The device is not ready for use"), raised by
# DeviceWatcher.start() when the Bluetooth radio is off/unavailable.
_HRESULT_DEVICE_NOT_READY = -2147020577


@dataclass
class DiscoveredDevice:
    name: str
    address: str  # "AA:BB:CC:DD:EE:FF"


async def scan(timeout_seconds: float = 10.0, debug: bool = False) -> list[DiscoveredDevice]:
    """Discover nearby Bluetooth devices, classic and BLE alike (Windows only).

    Uses WinRT device enumeration directly, not bleak: bleak is BLE-only and
    cannot see this device over its actual classic-BT transport
    (docs/PROTOCOL.md §0). Enumeration is intentionally unfiltered by
    protocol (see _AEP_BLUETOOTH_SELECTOR) since the Band 10 was observed
    dropping out of a classic-only AEP filter; callers should filter by
    DEVICE_NAME_RE for display.
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

    def log(msg: str) -> None:
        if debug:
            print(f"[scan] {msg}", file=sys.stderr)

    found: dict[str, str] = {}
    watcher = DeviceInformation.create_watcher_with_kind_aqs_filter_and_additional_properties(
        _AEP_BLUETOOTH_SELECTOR, [], DeviceInformationKind.ASSOCIATION_ENDPOINT
    )

    def on_added(_watcher: object, info: object) -> None:
        found.setdefault(info.id, info.name)  # type: ignore[attr-defined]
        log(f"added id={info.id!r} name={info.name!r}")  # type: ignore[attr-defined]

    watcher.add_added(on_added)
    watcher.add_enumeration_completed(
        lambda *_: log(f"enumeration completed, {len(found)} device(s) so far")
    )
    watcher.add_stopped(lambda *_: log(f"watcher stopped, status={watcher.status}"))

    log(f"status before start: {watcher.status}")
    try:
        watcher.start()
    except OSError as e:
        if e.winerror == _HRESULT_DEVICE_NOT_READY:
            raise RuntimeError(
                "Bluetooth radio is off or unavailable. Turn on Bluetooth in "
                "Windows settings and try again."
            ) from e
        raise
    log(f"status after start: {watcher.status}")
    try:
        elapsed = 0.0
        interval = 2.0
        while elapsed < timeout_seconds:
            step = min(interval, timeout_seconds - elapsed)
            await asyncio.sleep(step)
            elapsed += step
            log(f"t={elapsed:.0f}s status={watcher.status} found={len(found)}")
    finally:
        watcher.stop()

    devices = []
    for device_id, name in found.items():
        bt_device = await BluetoothDevice.from_id_async(device_id)
        if bt_device is not None:
            addr = bt_device.bluetooth_address
            address = ":".join(
                f"{(addr >> (8 * i)) & 0xFF:02X}" for i in reversed(range(6))
            )
        else:
            # Not resolvable as classic BT (e.g. a BLE AEP entry) -- show the
            # raw AEP id rather than dropping the device from the list.
            address = device_id
        devices.append(DiscoveredDevice(name=name or "(no name)", address=address))
    return devices


async def list_paired() -> list[DiscoveredDevice]:
    """List classic-BT devices already paired in Windows (no discovery, no
    Location privacy gate -- queries known device interfaces, not nearby
    proximity/AEP endpoints). Use when pairing was completed via Windows
    Settings but `scan()` can't discover the device (e.g. Location access
    disabled for desktop apps).
    """
    if sys.platform != "win32":
        raise RuntimeError(
            "Bluetooth is only available on native Windows (see CLAUDE.md); "
            "this can't run under WSL/Linux."
        )

    from winrt.windows.devices.bluetooth import BluetoothDevice
    from winrt.windows.devices.enumeration import DeviceInformation

    selector = BluetoothDevice.get_device_selector_from_pairing_state(True)
    infos = await DeviceInformation.find_all_async_aqs_filter(selector)

    devices = []
    for info in infos:
        bt_device = await BluetoothDevice.from_id_async(info.id)
        if bt_device is None:
            continue
        addr = bt_device.bluetooth_address
        mac = ":".join(f"{(addr >> (8 * i)) & 0xFF:02X}" for i in reversed(range(6)))
        devices.append(DiscoveredDevice(name=info.name or "(no name)", address=mac))
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
