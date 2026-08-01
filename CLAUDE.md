# miband — iOS-only Gadgetbridge equivalent for Xiaomi Smart Band 10

End goal: an iOS app that talks to the Xiaomi Smart Band 10 over BLE, stores
data locally, writes it to Apple Health, sideloaded (AltStore/SideStore),
never through the App Store.

**Decision (2026-08-02): Windows/Python is retired. iOS is the only active
target now.** `src/miband/` (the Phase 0 Python CLI) is kept as read-only
reference — it validated the protocol and produced `docs/PROTOCOL.md` plus
the `fixtures/*.jsonl` captures, which remain the spec and test fixtures for
the iOS app. Do not add new Python transport/auth code; do not resume the
classic-RFCOMM/Windows path. All new work happens under `ios/`.

## Hard constraints

- **Transport is BLE GATT (CoreBluetooth), not classic RFCOMM.** Classic-BT
  RFCOMM was Android/Gadgetbridge's transport and is unreachable from iOS
  without MFi certification (confirmed empty
  `EAAccessoryManager.connectedAccessories` on real hardware). The band also
  serves a full BLE GATT interface in parallel — service `FE95`, RX `005E`,
  TX `005F` — reusing the classic side's SPP-V2 packet framing verbatim over
  BLE notify/write. This is verified on real hardware, not a guess: see
  `docs/PROTOCOL.md` §0/§0a/§2.3 and `fixtures/session-20260801-fe95-ble-v2.jsonl`.
- **BLE doesn't work in WSL, and the simulator has no real Bluetooth radio.**
  Every hardware-in-the-loop test needs a physical iPhone. Build via Xcode or
  the existing unsigned-IPA GitHub Actions workflows
  (`.github/workflows/manumit-ipa.yml`, `mficheck-ipa.yml`) and sideload.
- **Licensing.** This repo derives from Gadgetbridge (AGPLv3) and is AGPLv3.
  `LICENSE` at repo root; add a short header to new source files (Swift
  included). One exception:
  `PiotrMachowski/Xiaomi-cloud-tokens-extractor` is MIT — keep that code in
  `vendor/xiaomi_cloud/` with its original MIT header intact, never mixed
  into an AGPLv3 file.
- **No network calls to Xiaomi except the account-login flow** needed to
  fetch the auth key. No telemetry, no analytics, ever.
- **Secrets** (auth key, account credentials, MAC/peripheral identifier)
  never get committed or logged — Keychain on iOS, redact in all log/fixture
  output. The auth key itself can still be fetched with the Python tool
  (`uv run miband auth-key`, M2, already working) and copied into the iOS
  app once; that flow doesn't need porting to Swift unless we later want the
  iOS app to do its own Xiaomi-account login.

## Reference material (gitignored, not committed)

- `/reference/Gadgetbridge` — read the Xiaomi protocol implementation under
  `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/xiaomi/`
  and `app/src/main/proto/xiaomi.proto`. Reimplement in Swift from
  understanding, never copy Java.
- `proto/xiaomi.proto` is vendored unmodified from Gadgetbridge. Not wired
  up via `swift-protobuf` yet — `ios/Manumit/ProtoWire.swift` hand-encodes/
  decodes just the auth messages (Command/Auth/PhoneNonce/WatchNonce/
  AuthStep3/AuthDeviceInfo) to avoid an unverified SPM package reference in
  the `.xcodeproj`. Switch to real `swift-protobuf` against this file once
  the app needs more than the handful of hand-rolled messages.

## What exists already

- `src/miband/` — Phase 0 Python CLI, **reference-only, frozen.** Confirmed
  SPP-V2 framing/CRC (`protocol.py`, 17 offline tests), M0-M2 done (scan via
  WinRT, `auth-key` via the vendored MIT token extractor). `auth.py`/M3
  handshake was never finished on this path — don't finish it here, redo it
  in Swift instead.
- `docs/PROTOCOL.md` — the protocol spec, transport-agnostic where it can be
  (framing, handshake, encryption, command catalog) plus a `§0a` section
  specifically for the verified iOS BLE-GATT surface. Keep updating this
  doc, not just Swift comments — it's still the shared source of truth.
- `ios/MFiCheck/` — throwaway diagnostic app (built unsigned via
  `.github/workflows/mficheck-ipa.yml`, sideloaded). Confirmed MFi is a dead
  end and BLE-GATT (`FE95`/`005E`/`005F`) is reachable and correct. Frozen —
  don't add features here, it did its job.
- `ios/Manumit/` — the real app, new Xcode project (built unsigned via
  `.github/workflows/manumit-ipa.yml`, sideloaded). Connects to
  `FE95`/`005E`/`005F`, runs the SPP-V2 session framing and the §3 auth
  handshake, automatic fixture logging per the instrumentation rule below.
  This is where the app keeps growing.

## Instrumentation

Every BLE frame gets logged to `fixtures/session-<timestamp>.jsonl`:
direction, characteristic, raw hex, monotonic timestamp, decoded
interpretation once known. Non-negotiable — these are the test fixtures for
protocol work, and every session against real hardware is expensive to
reproduce. Already implemented in `ios/Manumit` — keep it working as the app
grows.

## Working style

- When the band's behaviour contradicts `docs/PROTOCOL.md`, update the doc
  in the same commit as the code fix.
- Milestones stop for hardware-in-the-loop testing — implement one, state
  what to build/sideload and what success looks like, then stop. Don't
  chain milestones.
- If a milestone is blocked by something structural, say so and stop rather
  than working around it.
