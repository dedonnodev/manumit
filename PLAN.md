# Claude Code — Phase 0 kickoff prompt

_(Copy everything below the line into a fresh Claude Code session in an empty repo.)_

---

We are starting an open-source project. The end goal is an iOS app that talks to a
Xiaomi Smart Band 10 over BLE, stores all data locally, and writes it to Apple Health —
a Gadgetbridge equivalent for iPhone, distributed via sideloading (AltStore/SideStore),
never through the App Store.

**This session is Phase 0 only: a Python CLI that proves the protocol works.**
The Python tool is throwaway tooling. Its real deliverable is a validated
`PROTOCOL.md` plus a corpus of captured packets, which will become the spec and the
test fixtures for the Swift implementation in Phase 1. Optimize for _understanding
and documenting the protocol_, not for building a nice Python app.

## Hard constraints

- **Bluetooth does not work from WSL.** I develop in WSL but BLE is not available
  there. The Python CLI must run on native Windows (Python 3.12 + `bleak`, which uses
  the WinRT backend). Do not use `bluepy`, `pygatt`, `dbus`, or anything Linux-only.
  Keep all BLE code behind a thin transport interface so it stays testable off-device.
- **Licensing.** We derive from Gadgetbridge, which is AGPLv3. This repo is AGPLv3.
  Add `LICENSE` and per-file headers. One exception:
  `PiotrMachowski/Xiaomi-cloud-tokens-extractor` is MIT — check its `LICENSE` yourself
  to confirm, and if so keep that code in a clearly separated directory with its
  original MIT header and attribution intact. Never mix the two in one file.
- **No network calls to Xiaomi except the account-login flow** needed to fetch the
  auth key. No telemetry, no analytics, ever.
- Secrets (auth key, account credentials, MAC address) go in a gitignored `.env`.
  Never commit them, never log them. Redact them in all log output.

## Reference material

Clone these read-only into `/reference` (gitignored, never committed):

- `https://codeberg.org/Freeyourgadget/Gadgetbridge` — the relevant code is under
  `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/xiaomi/`
  and the `.proto` definitions in the same tree.
- `https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor`

Read Gadgetbridge's Xiaomi package thoroughly before writing any code. Do not copy
Java into the repo. Reimplement in Python from what you understand, and write down
what you understood.

The `.proto` files are the key asset: they are the bridge between Phase 0 and Phase 1.
Vendor them into `proto/`, generate Python bindings with `grpcio-tools`, and keep them
unmodified so `swift-protobuf` can consume the exact same files later.

## Target repo layout

```
proto/              # vendored .proto files, unmodified
src/miband/
  transport.py      # abstract transport + bleak implementation
  auth.py           # handshake / encryption
  protocol.py       # framing, encode/decode
  activity.py       # activity record parsing
  cli.py
vendor/xiaomi_cloud/  # MIT-licensed token extractor, kept separate
tests/
fixtures/           # captured packets as JSONL (hex + timestamp + direction)
docs/PROTOCOL.md    # the real deliverable
CLAUDE.md
```

## Instrumentation requirement

From the very first connection attempt, log **every** BLE frame to
`fixtures/session-<timestamp>.jsonl`: direction, characteristic UUID, raw hex,
monotonic timestamp, and a decoded interpretation once we have one. This is
non-negotiable — those files are the test fixtures for the Swift port, and every
session with the physical band is expensive to reproduce.

## Milestones — stop after each one and wait for me

I have to run each step against real hardware, so do not chain milestones.
Implement one, tell me exactly what command to run and what output means success,
then stop.

**M0 — Scaffolding.** Repo layout, `pyproject.toml` (use `uv`), AGPLv3 license,
`CLAUDE.md` capturing the constraints above. Read the Gadgetbridge Xiaomi package and
write the first draft of `docs/PROTOCOL.md`: transport, service and characteristic
UUIDs, frame format, handshake sequence, encryption scheme, activity record layout.
Mark every claim as `[verified]` or `[from source, untested]`.

**M1 — Scan.** CLI command that scans for BLE peripherals and prints, for a chosen
device, its full GATT tree: services, characteristics, properties, descriptors.
Goal: confirm the band exposes the Xiaomi service over BLE and compare what we see
against what `PROTOCOL.md` predicts. Update the doc with what we actually observe.

**M2 — Auth key.** Wire up the MIT token extractor so I can log into my Xiaomi
account and retrieve the band's auth key from the CLI. Cache it in `.env`.
Document the exact HTTP flow in `docs/TOKEN.md` — this gets ported to Swift later,
so describe the request sequence, signing, and response shapes precisely.

**M3 — Handshake.** Implement authentication against the band. Success criterion:
the band accepts us and we can read device info (firmware version, serial, battery).
This is the make-or-break milestone.

**M4 — Activity sync.** Fetch stored activity records and decode them: steps, heart
rate, sleep stages, SpO2, calories. Dump to JSON. Compare a day's numbers against what
Mi Fitness shows and report any discrepancy rather than silently trusting our parser.

**M5 — Offline test suite.** Replay tests that run entirely from `fixtures/` with no
hardware and no network, covering framing, decryption, and activity parsing. These
tests are the acceptance criteria the Swift implementation will have to match.

## Working style

- Ask before installing anything beyond `bleak`, `protobuf`, `grpcio-tools`,
  `cryptography`, `click`, `pytest`, `python-dotenv`.
- When the band's behaviour contradicts `PROTOCOL.md`, update the doc in the same
  commit as the code fix. The doc drifting from reality is the main failure mode here.
- If a milestone turns out to be blocked by something structural, say so plainly and
  stop rather than working around it.

Start with M0.
