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
"""SPP-V2 packet framing and encode/decode (see docs/PROTOCOL.md §2.3).

SPP-V1 (§2.2) is not implemented yet -- it's only needed for the one-off
version-negotiation packet at connection start (§2.1); everything else on
this device is SPP-V2, confirmed on real hardware
(`fixtures/session-20260801-fe95-ble-v2.jsonl`).
"""

from dataclasses import dataclass

PREAMBLE = b"\xa5\xa5"

PACKET_TYPE_ACK = 1
PACKET_TYPE_SESSION_CONFIG = 2
PACKET_TYPE_DATA = 3


def crc16_arc(data: bytes) -> int:
    """CRC-16/ARC: poly 0x8005 reflected (0xA001), init 0, no xorout (§2.3)."""
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


@dataclass
class SppV2Packet:
    packet_type: int
    sequence: int
    payload: bytes


def encode_v2(packet: SppV2Packet) -> bytes:
    return (
        PREAMBLE
        + bytes([packet.packet_type, packet.sequence])
        + len(packet.payload).to_bytes(2, "little")
        + crc16_arc(packet.payload).to_bytes(2, "little")
        + packet.payload
    )


def decode_v2(buf: bytes) -> tuple[SppV2Packet, int] | None:
    """Decode one packet from the start of `buf`.

    Returns `(packet, bytes_consumed)`, or `None` if `buf` doesn't yet
    contain a full packet -- RFCOMM/BLE notify give no framing of their own,
    so callers buffer bytes across reads and call this again (§2.3).
    """
    if len(buf) < 8:
        return None
    if buf[0:2] != PREAMBLE:
        raise ValueError(f"bad SPP-V2 preamble: {buf[0:2].hex()}")
    packet_type = buf[2]
    sequence = buf[3]
    length = int.from_bytes(buf[4:6], "little")
    checksum = int.from_bytes(buf[6:8], "little")
    total = 8 + length
    if len(buf) < total:
        return None
    payload = buf[8:total]
    actual = crc16_arc(payload)
    if actual != checksum:
        raise ValueError(
            f"SPP-V2 checksum mismatch: header says {checksum:#06x}, "
            f"computed {actual:#06x}"
        )
    return SppV2Packet(packet_type, sequence, payload), total
