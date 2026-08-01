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
"""M2: wires up vendor/xiaomi_cloud/token_extractor.py (MIT, unmodified).

Runs it as a subprocess -- never imported -- to keep the MIT/AGPL boundary
clean (see vendor/xiaomi_cloud/README.md). Parses its JSON dump to find the
Band 10's `beaconkey` (BLE auth key, docs/TOKEN.md) and deletes the dump
immediately after, since it contains every device/token on the account, not
just the band's.
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

VENDOR_SCRIPT = (
    Path(__file__).resolve().parent.parent.parent
    / "vendor"
    / "xiaomi_cloud"
    / "token_extractor.py"
)

_REQUIRED_MODULES = ["requests", "Crypto", "PIL", "colorama"]


def check_dependencies() -> None:
    missing = [m for m in _REQUIRED_MODULES if importlib.util.find_spec(m) is None]
    if missing:
        raise RuntimeError(
            "Missing dependencies for the Xiaomi cloud token extractor "
            f"({', '.join(missing)}). Run: uv sync --extra xiaomi-cloud"
        )


def run_extractor(server: str | None = None) -> Path:
    """Run the vendored extractor interactively; return path to its JSON dump.

    Inherits stdin/stdout/stderr so you get its normal login prompts
    (username/password or QR code, captcha, 2FA). Note: the vendored tool
    prints each device's key to its own stdout as it runs -- that's upstream
    behaviour we don't control by leaving it unmodified; we don't log it
    anywhere ourselves.
    """
    check_dependencies()
    fd, output_path = tempfile.mkstemp(suffix=".json", prefix="miband-xiaomi-cloud-")
    os.close(fd)
    cmd = [sys.executable, str(VENDOR_SCRIPT), "-o", output_path]
    if server:
        cmd += ["-s", server]
    subprocess.run(cmd, check=True)
    return Path(output_path)


def find_beaconkey(dump_path: Path, mac: str | None = None) -> list[dict]:
    """Return BLE devices (did contains "blt") with a resolved beaconkey."""
    data = json.loads(dump_path.read_text())
    normalized_mac = _normalize_mac(mac) if mac else None
    matches = []
    for server_entry in data:
        for home in server_entry.get("homes", []):
            for device in home.get("devices", []):
                did = device.get("did", "")
                ble_data = device.get("BLE_DATA")
                if "blt" not in did or not ble_data or "beaconkey" not in ble_data:
                    continue
                if normalized_mac and _normalize_mac(device.get("mac", "")) != normalized_mac:
                    continue
                matches.append(device)
    return matches


def _normalize_mac(mac: str) -> str:
    return mac.replace(":", "").replace("-", "").upper()
