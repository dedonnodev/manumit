# miband

Phase 0 of a Gadgetbridge-equivalent for iPhone: a throwaway Python CLI that
validates the Xiaomi Smart Band 10 protocol over Bluetooth Classic RFCOMM and
produces `docs/PROTOCOL.md` plus packet fixtures for a future Swift/iOS port.

See `CLAUDE.md` for constraints, `docs/PROTOCOL.md` for the protocol spec,
`docs/TOKEN.md` for the Xiaomi-cloud login flow.

AGPLv3 — see `LICENSE`.

## Status: M0-M2 done, needs a run on real Windows hardware

Nothing past M0 has touched real hardware or a real account yet. This repo
was built in WSL, where Bluetooth doesn't work at all — everything below
needs to happen on native Windows.

### 1. Set up

```
uv sync
```

### 2. M1 — scan (`docs/PROTOCOL.md` §1a)

```
uv run miband scan
```

Success: your band shows up within ~10s, marked `<-- Xiaomi Smart Band 10`,
with a MAC address next to it. Save that MAC — M2's `--mac` and later
milestones want it.

If nothing shows up or it errors: the AEP selector GUID in
`transport.py::scan()` is unverified platform knowledge, not something read
from source — report back exactly what happened so `docs/PROTOCOL.md` §1a
can be corrected.

### 3. M2 — auth key (`docs/TOKEN.md`)

```
uv sync --extra xiaomi-cloud
uv run miband auth-key --mac <MAC from step 2>
```

Walks you through the same interactive login as the standalone
Xiaomi-cloud-tokens-extractor (username/password or QR, possibly a captcha
or email 2FA code). Success: `Stored auth key for ... in .env`, and `.env`
now has `MIBAND_AUTH_KEY` (and `MIBAND_MAC`).

Note: the underlying tool prints the raw key to its own stdout as it runs —
that's upstream behavior (`vendor/xiaomi_cloud/`, unmodified), not something
this project logs anywhere else.

### Not built yet

- **M3 — handshake.** Connect over RFCOMM and authenticate using the M2 key.
  Make-or-break milestone; needs M1+M2 confirmed working first.
- **M4 — activity sync.** Fetch and decode steps/HR/sleep/SpO2/calories.
- **M5 — offline test suite** replaying `fixtures/` with no hardware.

Report M1/M2 results (what `scan` printed, whether `auth-key` succeeded)
before M3 gets written — both feed corrections into `docs/PROTOCOL.md` and
`docs/TOKEN.md`.
