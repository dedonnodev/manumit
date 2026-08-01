from miband.proto_gen import xiaomi_pb2


def test_command_roundtrip():
    cmd = xiaomi_pb2.Command(type=1, subtype=26)
    cmd.auth.phoneNonce.nonce = b"\x00" * 16
    data = cmd.SerializeToString()
    assert xiaomi_pb2.Command.FromString(data) == cmd
