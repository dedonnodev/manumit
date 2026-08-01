from miband.protocol import (
    PACKET_TYPE_ACK,
    PACKET_TYPE_DATA,
    PACKET_TYPE_SESSION_CONFIG,
    SppV2Packet,
    crc16_arc,
    decode_v2,
    encode_v2,
)

# Real bytes from fixtures/session-20260801-fe95-ble-v2.jsonl (manual capture)
# and fixtures/session-20260801-235708.jsonl (automatic fixture logging, real
# monotonic timestamps), verified on hardware (docs/PROTOCOL.md §0a/§2.3).

def _hex(s: str) -> bytes:
    return bytes.fromhex(s.replace(" ", ""))


SESSION_CONFIG_RESPONSE = _hex(
    "A5 A5 02 00 16 00 15 19 02 01 03 00 03 00 41 02 02 00 00 80 "
    "03 02 00 03 00 04 02 00 80 3E"
)
ACK_SEQ0 = _hex("A5 A5 01 00 00 00 00 00")
STARTSESSION_REQUEST = _hex(
    "A5 A5 02 00 16 00 1D 4D 01 01 03 00 01 00 00 02 02 00 00 FC "
    "03 02 00 20 00 04 02 00 10 27"
)
WATCHNONCE_DATA = _hex(
    "A5 A5 03 00 3F 00 E9 5F 01 01 08 01 10 1A 1A 37 FA 01 34 0A "
    "10 15 70 E7 5F 39 BB 2D 00 33 B1 11 78 E2 71 51 41 12 20 B6 "
    "9E 06 71 77 20 78 92 E9 8D 6E 60 30 FF 57 8A 06 99 48 F0 67 "
    "F8 1D 9B 59 42 6C 94 DF 19 69 69"
)


def test_crc16_arc_matches_header_checksum():
    payload = SESSION_CONFIG_RESPONSE[8:]
    assert crc16_arc(payload) == 0x1915


def test_decode_v2_session_config_response():
    pkt, consumed = decode_v2(SESSION_CONFIG_RESPONSE)
    assert consumed == len(SESSION_CONFIG_RESPONSE)
    assert pkt.packet_type == PACKET_TYPE_SESSION_CONFIG
    assert pkt.sequence == 0
    assert len(pkt.payload) == 22


def test_decode_v2_ack():
    pkt, consumed = decode_v2(ACK_SEQ0)
    assert consumed == 8
    assert pkt.packet_type == PACKET_TYPE_ACK
    assert pkt.payload == b""


def test_decode_v2_data_watchnonce():
    pkt, consumed = decode_v2(WATCHNONCE_DATA)
    assert consumed == len(WATCHNONCE_DATA)
    assert pkt.packet_type == PACKET_TYPE_DATA
    assert pkt.sequence == 0
    assert len(pkt.payload) == 63
    raw_channel, op_code = pkt.payload[0], pkt.payload[1]
    assert raw_channel == 1  # Protobuf
    assert op_code == 1  # PLAINTEXT


def test_decode_v2_incomplete_buffer_returns_none():
    assert decode_v2(SESSION_CONFIG_RESPONSE[:10]) is None
    assert decode_v2(b"\xa5\xa5") is None


def test_decode_v2_bad_preamble_raises():
    import pytest

    with pytest.raises(ValueError, match="preamble"):
        decode_v2(b"\x00\x00\x01\x00\x00\x00\x00\x00")


def test_decode_v2_bad_checksum_raises():
    import pytest

    corrupt = bytearray(SESSION_CONFIG_RESPONSE)
    corrupt[8] ^= 0xFF
    with pytest.raises(ValueError, match="checksum"):
        decode_v2(bytes(corrupt))


def test_encode_v2_matches_captured_startsession_request():
    pkt = SppV2Packet(
        packet_type=PACKET_TYPE_SESSION_CONFIG,
        sequence=0,
        payload=_hex("01 01 03 00 01 00 00 02 02 00 00 FC 03 02 00 20 00 04 02 00 10 27"),
    )
    assert encode_v2(pkt) == STARTSESSION_REQUEST


def test_encode_decode_roundtrip():
    pkt = SppV2Packet(packet_type=PACKET_TYPE_DATA, sequence=42, payload=b"hello world")
    encoded = encode_v2(pkt)
    decoded, consumed = decode_v2(encoded)
    assert consumed == len(encoded)
    assert decoded == pkt


# Real bytes from fixtures/session-20260801-235708.jsonl (automatic fixture
# logging, real monotonic timestamps -- docs/PROTOCOL.md §0a/§2.3). Records
# 18+19: a single 599-byte Data payload arrived split across two separate
# BLE notify events on 005E -- the first chunk alone is 8+487=495 bytes,
# short of the declared 607-byte total.
DATA_SEQ9_CHUNK1 = _hex(
    "A5 A5 03 09 57 02 9F 7D 01 02 26 C6 0B 0C A7 18 05 99 D9 F4 8B E4 34 64 "
    "1F C7 46 DF 71 AF 62 7A F2 20 0B D6 B4 FF B1 84 84 0C 28 40 63 6E 0A 55 "
    "FC 40 BD 4D 78 AA 3C 9F 21 8E 98 6C 38 FF 9C 52 65 20 44 63 BA 0B 0B 85 "
    "28 4D 5B 9C 1B C6 42 16 4D D1 4C AF 66 B7 E3 54 82 4C 2D BB 9F D3 6D 16 "
    "FD 53 E1 DD B6 FB CC 13 58 AE 2B 26 E5 AE 2D F3 EB E5 8B C9 3E 11 E9 0F "
    "89 FA 58 40 AD 0A 33 13 33 83 5D DD 93 62 E3 14 80 49 F3 58 BD 17 F6 C2 "
    "36 7F 3C 6A E1 EA 71 92 DE B8 4B 47 50 21 EC EE D0 E2 D2 B3 D8 91 21 BA "
    "F4 6A 2D 36 77 50 80 C8 B5 D8 29 A4 3B 31 7E B5 F6 F0 06 43 65 BE 16 EB "
    "B2 B8 64 06 7C D0 AF CB 7C 55 E7 36 3C 0C 64 DC C5 89 84 F1 B0 02 71 E6 "
    "CB DE EA 01 2D 9B 38 A0 C9 BB EF 26 40 B5 1A E1 0D 99 9F 18 C6 B9 EE 1B "
    "A2 9C 66 F7 B7 BB 4E B9 55 41 4D E1 5A C6 B2 15 B0 AF 7D B1 52 67 5F 3A "
    "CE C1 09 44 70 7F C5 07 9A 5D 07 0A 6E A7 6E 41 98 77 59 17 4B 66 AA E2 "
    "51 63 A9 A4 98 9D C7 55 D7 C2 5C 2E D2 AE BD 7E 29 3E A4 C9 79 8F A4 F4 "
    "27 9D D1 82 80 E4 80 78 9F A0 F2 CC 9D 3C 78 33 2D EC 39 22 21 8C CC F5 "
    "A9 A4 93 A2 1F DC 94 43 90 B7 D0 B5 A7 6C D9 5A 9A CA A7 73 5E B7 87 76 "
    "60 8B 27 D3 D2 58 4D 3F 30 89 7C A7 41 28 83 90 0B 3C 0B F5 C3 2B 5F C2 "
    "46 FF 7E 29 D8 11 2A C8 23 F1 79 33 6E 67 3E 89 59 9C F9 0E 99 7B 3A F5 "
    "FB A6 C2 57 40 0B CF 43 35 74 5E 08 DF AF F0 26 51 A2 5B F0 44 16 9D FD "
    "54 0A 19 CF BE 06 11 D1 AF C3 B6 89 D9 41 A9 FC A5 4B E5 01 26 CC 29 46 "
    "D8 D0 25 42 84 83 1D 45 9E C4 55 0D 98 28 38 BB 06 93 9A F5 16 A4 FC 35 "
    "CA E0 0F B1 FC 7A 94 FE F5 12 85 E3 B4 53 26"
)
DATA_SEQ9_CHUNK2 = _hex(
    "B0 BF E4 FA 55 3B 12 2B 5C 5A E6 6A 2F 91 BE E5 D6 E1 EB DD D6 71 FE F6 "
    "34 1B 98 C1 E5 B1 AA 3D 32 81 4F CA FD B5 64 B1 6B DF 4A 15 39 A0 59 36 "
    "08 D5 8B 92 49 B4 62 93 09 2B 1E 4D 0D C3 68 D2 17 BE B8 98 56 F0 54 8A "
    "43 F5 95 32 D0 D3 13 01 7C 90 5B 1A EA BE 25 A8 D4 30 8F 46 F8 67 1E 35 "
    "58 B3 A3 71 40 68 75 A2 50 4B 8A 75 23 0C E1 DD"
)

# Records 20-23: raw_channel=5 (Activity) actually observed on the wire for
# the first time -- previously only [from source, untested].
ACTIVITY_DATA_SEQ10 = _hex(
    "A5 A5 03 0A 68 00 53 BA 05 02 2F C2 1A 0C 29 BC 6F F9 1A F4 81 BC C1 97 "
    "D6 3A 89 19 40 98 50 AF C1 14 3B 81 42 FB A9 84 A4 0D 00 C0 E3 6A 3A B4 "
    "B6 47 5B 89 2B 4F 80 10 10 D6 9F 06 2E F5 95 83 56 14 76 36 69 3C 39 BD "
    "3A 44 6A A9 2B FF 7A C2 74 E5 7B A1 94 B9 EA 65 B1 78 1F 8A A8 E4 5F CF "
    "EF 5A D0 8C 62 C2 F5 27 61 9B 1A B6 D1 55 49 37"
)


def test_decode_v2_incomplete_until_second_ble_notify_chunk():
    """A 599-byte payload split 487+112 across two 005E notify events --
    the first chunk is incomplete on its own."""
    assert decode_v2(DATA_SEQ9_CHUNK1) is None
    pkt, consumed = decode_v2(DATA_SEQ9_CHUNK1 + DATA_SEQ9_CHUNK2)
    assert consumed == len(DATA_SEQ9_CHUNK1) + len(DATA_SEQ9_CHUNK2)
    assert pkt.packet_type == PACKET_TYPE_DATA
    assert pkt.sequence == 9
    assert len(pkt.payload) == 599
    assert pkt.payload[0] == 1  # Protobuf channel, matches surrounding traffic


def test_decode_v2_activity_channel():
    pkt, consumed = decode_v2(ACTIVITY_DATA_SEQ10)
    assert consumed == len(ACTIVITY_DATA_SEQ10)
    raw_channel, op_code = pkt.payload[0], pkt.payload[1]
    assert raw_channel == 5  # Activity
    assert op_code == 2  # ENCRYPTED
