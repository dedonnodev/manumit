import json

from miband.xiaomi_cloud import _normalize_mac, find_beaconkey

DUMP = [
    {
        "server": "de",
        "homes": [
            {
                "home_id": 1,
                "devices": [
                    {"did": "lumi.123", "name": "Not BLE", "mac": "AA:AA:AA:AA:AA:AA"},
                    {
                        "did": "blt.3.abcdef",
                        "name": "Xiaomi Smart Band 10 1234",
                        "mac": "11:22:33:44:55:66",
                        "BLE_DATA": {"beaconkey": "deadbeefdeadbeefdeadbeefdeadbeef"},
                    },
                    {
                        "did": "blt.3.other",
                        "name": "Some other BLE thing",
                        "mac": "AA:BB:CC:DD:EE:FF",
                        "BLE_DATA": {"beaconkey": "00000000000000000000000000000000"},
                    },
                ],
            }
        ],
    }
]


def test_normalize_mac():
    assert _normalize_mac("11:22:33:44:55:66") == "112233445566"
    assert _normalize_mac("11-22-33-44-55-66") == "112233445566"


def test_find_beaconkey_filters_non_ble_devices(tmp_path):
    dump = tmp_path / "dump.json"
    dump.write_text(json.dumps(DUMP))
    matches = find_beaconkey(dump)
    assert len(matches) == 2
    assert all("blt" in m["did"] for m in matches)


def test_find_beaconkey_filters_by_mac(tmp_path):
    dump = tmp_path / "dump.json"
    dump.write_text(json.dumps(DUMP))
    matches = find_beaconkey(dump, mac="11:22:33:44:55:66")
    assert len(matches) == 1
    assert matches[0]["name"] == "Xiaomi Smart Band 10 1234"
