# Vendored proto

`xiaomi.proto` is copied unmodified from
[Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge)
(`app/src/main/proto/xiaomi.proto`, AGPLv3), so the Swift port in Phase 1 can
consume the exact same file via `swift-protobuf`. Do not edit it here —
port changes upstream instead.

## Regenerating Python bindings

Generated code is gitignored (`src/miband/proto_gen/`); regenerate with:

```
uv run python -m grpc_tools.protoc -I proto --python_out=src/miband/proto_gen proto/xiaomi.proto
```
