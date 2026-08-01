# miband — Phase 0 (Python protocol validation CLI)

This is throwaway tooling. The real deliverable is `docs/PROTOCOL.md` plus
`fixtures/*.jsonl` packet captures — the spec and test fixtures for a future
Swift/iOS implementation (Phase 1, not started here). Optimize for
understanding and documenting the protocol, not for a nice Python app.

## Hard constraints

- **Transport is Bluetooth Classic RFCOMM (SPP), not BLE.** The Xiaomi Smart
  Band 10 connects over classic Bluetooth (`ConnectionType.BT_CLASSIC` in
  Gadgetbridge), not GATT. Use the stdlib `socket` module's
  `AF_BLUETOOTH`/`BTPROTO_RFCOMM` support on native Windows — no BLE library
  (`bleak` etc.) is needed for this device. See `docs/PROTOCOL.md` §1 for
  citations. This corrects the original Phase 0 brief, which assumed BLE.
- **Bluetooth does not work from WSL.** Develop in WSL, but Bluetooth is not
  available there. The CLI must run on native Windows (Python 3.12). Keep all
  Bluetooth I/O behind a thin transport interface (`src/miband/transport.py`)
  so it stays testable off-device.
- **Licensing.** This repo derives from Gadgetbridge (AGPLv3) and is AGPLv3.
  `LICENSE` at repo root; add a short header to new source files. One
  exception: `PiotrMachowski/Xiaomi-cloud-tokens-extractor` is MIT — keep that
  code in `vendor/xiaomi_cloud/` with its original MIT header intact, never
  mixed into an AGPLv3 file.
- **No network calls to Xiaomi except the account-login flow** needed to fetch
  the auth key. No telemetry, no analytics, ever.
- **Secrets** (auth key, account credentials, MAC address) go in a gitignored
  `.env`. Never commit, never log — redact in all log output.

## Reference material (gitignored, not committed)

- `/reference/Gadgetbridge` — read the Xiaomi protocol implementation under
  `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/xiaomi/`
  and `app/src/main/proto/xiaomi.proto`. Reimplement in Python from
  understanding, never copy Java.
- `/reference/Xiaomi-cloud-tokens-extractor` — MIT-licensed auth key
  retrieval tool, vendored unmodified into `vendor/xiaomi_cloud/` and run as
  a subprocess by `miband auth-key` (`src/miband/xiaomi_cloud.py`, AGPL —
  never imports the vendored file directly). HTTP flow documented in
  `docs/TOKEN.md`.

`proto/xiaomi.proto` is vendored unmodified from Gadgetbridge so
`swift-protobuf` can consume the exact same file in Phase 1.

## Instrumentation

Every BLE/RFCOMM frame gets logged to `fixtures/session-<timestamp>.jsonl`:
direction, raw hex, monotonic timestamp, decoded interpretation once known.
Non-negotiable — these are the Swift port's test fixtures, and every session
against real hardware is expensive to reproduce.

## Working style

- Ask before installing anything beyond: `protobuf`, `grpcio-tools`,
  `cryptography`, `click`, `pytest`, `python-dotenv`. Exception already
  approved: `requests`/`pycryptodome`/`Pillow`/`colorama`, but only in the
  `xiaomi-cloud` optional extra (`uv sync --extra xiaomi-cloud`) — needed
  solely to run the vendored MIT token extractor, kept out of the default
  install.
- When the band's behaviour contradicts `docs/PROTOCOL.md`, update the doc in
  the same commit as the code fix.
- Milestones stop for hardware-in-the-loop testing — implement one, state the
  command to run and what success looks like, then stop. Don't chain
  milestones.
- If a milestone is blocked by something structural, say so and stop rather
  than working around it.
