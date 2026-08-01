import sys

import pytest

from miband.transport import DEVICE_NAME_RE, scan


def test_device_name_regex():
    assert DEVICE_NAME_RE.match("Xiaomi Smart Band 10 A1B2")
    assert not DEVICE_NAME_RE.match("Xiaomi Smart Band 9 A1B2")
    assert not DEVICE_NAME_RE.match("Xiaomi Smart Band 10 a1b2")


@pytest.mark.skipif(sys.platform == "win32", reason="guard only fires off Windows")
def test_scan_rejects_non_windows():
    with pytest.raises(RuntimeError, match="native Windows"):
        import asyncio

        asyncio.run(scan())
