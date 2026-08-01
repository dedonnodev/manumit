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
"""CLI entry point."""

import asyncio

import click
from dotenv import set_key

from . import transport, xiaomi_cloud


@click.group()
@click.version_option()
def main() -> None:
    """Throwaway CLI for validating the Xiaomi Smart Band 10 protocol."""


@main.command()
@click.option(
    "--timeout", default=10.0, show_default=True, help="Scan duration in seconds."
)
def scan(timeout: float) -> None:
    """Discover nearby classic-Bluetooth devices and flag the Band 10."""
    try:
        devices = asyncio.run(transport.scan(timeout))
    except RuntimeError as exc:
        raise click.ClickException(str(exc)) from exc
    if not devices:
        click.echo("No devices found.")
        return
    for device in devices:
        marker = (
            "  <-- Xiaomi Smart Band 10"
            if transport.DEVICE_NAME_RE.match(device.name)
            else ""
        )
        click.echo(f"{device.address}  {device.name}{marker}")


@main.command("auth-key")
@click.option(
    "--mac",
    default=None,
    help="Band's Bluetooth MAC (from `miband scan`), to disambiguate if your "
    "account has multiple BLE devices.",
)
@click.option(
    "--server",
    default=None,
    type=click.Choice(["cn", "de", "us", "ru", "tw", "sg", "in", "i2"]),
    help="Xiaomi cloud region. Omit to check all.",
)
@click.option(
    "--env-file",
    default=".env",
    type=click.Path(dir_okay=False),
    show_default=True,
    help="Where to store the auth key.",
)
def auth_key(mac: str | None, server: str | None, env_file: str) -> None:
    """Log into your Xiaomi account and store the band's BLE auth key.

    Requires `uv sync --extra xiaomi-cloud`. Runs the vendored
    Xiaomi-cloud-tokens-extractor interactively (see docs/TOKEN.md).
    """
    try:
        dump_path = xiaomi_cloud.run_extractor(server=server)
    except RuntimeError as exc:
        raise click.ClickException(str(exc)) from exc

    try:
        matches = xiaomi_cloud.find_beaconkey(dump_path, mac=mac)
    finally:
        dump_path.unlink(missing_ok=True)

    if not matches:
        suffix = f" matching MAC {mac}" if mac else ""
        raise click.ClickException(f"No BLE device with a beaconkey found{suffix}.")

    if len(matches) > 1:
        click.echo("Multiple BLE devices found; rerun with --mac to pick one:")
        for device in matches:
            click.echo(
                f"  {device.get('mac', '?')}  {device.get('name', '?')}  "
                f"({device.get('model', '?')})"
            )
        raise click.ClickException("Ambiguous match.")

    device = matches[0]
    key = device["BLE_DATA"]["beaconkey"]
    set_key(env_file, "MIBAND_AUTH_KEY", key)
    if device.get("mac"):
        set_key(env_file, "MIBAND_MAC", device["mac"])
    label = device.get("name") or device.get("model") or "device"
    click.echo(f"Stored auth key for {label} in {env_file} (ends in ...{key[-4:]}).")


if __name__ == "__main__":
    main()
