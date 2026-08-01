# Xiaomi Smart Band 10 protocol — draft spec

Status: **M0 draft**, derived entirely from reading Gadgetbridge source
(`/reference/Gadgetbridge`, AGPLv3, not committed to this repo). Nothing here
has been confirmed against the physical band yet — every claim is tagged
`[from source, untested]` unless a hardware session has confirmed it, in
which case it becomes `[verified]`. Update this doc in the same commit as
any code change that contradicts it.

Source citations point at file:line in Gadgetbridge as of commit
`1782f796027459ef361e4eab1fa3ba4bb1938359` (2026-08-01).

## 0. Corrected assumption: this is not BLE

**[from source, untested]** The original Phase 0 brief assumed the band
talks BLE GATT. It doesn't. `MiBand10Coordinator` declares
`ConnectionType.BT_CLASSIC`
(`devices/xiaomi/watches/MiBand10Coordinator.java:45-47`), and
`XiaomiSupport.createConnectionSpecificSupport()` maps `BT_CLASSIC` to
`XiaomiSppSupport`, never `XiaomiBleSupport`
(`service/devices/xiaomi/XiaomiSupport.java:120-132`). The device talks
**Bluetooth Classic RFCOMM (Serial Port Profile)**: a single bidirectional
byte stream, with a custom framing protocol multiplexing "channels" (auth,
protobuf commands, activity data, etc.) inside that stream — no separate GATT
characteristics per function.

Practical consequence: `bleak` (BLE-only, WinRT backend) cannot talk to this
device at all. Python's stdlib `socket` module supports Bluetooth RFCOMM on
Windows natively via `socket.AF_BLUETOOTH` / `socket.BTPROTO_RFCOMM` — no
extra dependency needed. `transport.py` should wrap an RFCOMM socket, not a
BLE GATT client. This still fits the "thin transport interface, testable
off-device" requirement from the brief.

## 1. Transport

**[from source, untested]**

- Bluetooth Classic, SPP profile. Service UUID is the standard SPP UUID
  `00001101-0000-1000-8000-00805F9B34FB`
  (`XiaomiUuids.java:26`, `UUID_SERVICE_SERIAL_PORT_PROFILE`).
- `XiaomiSppSupport` opens one RFCOMM socket to that UUID and both reads and
  writes framed packets over it (`XiaomiSppSupport.java:49-96`).
- Device name filter used by Gadgetbridge to identify a Band 10 during scan:
  regex `^Xiaomi Smart Band 10 [0-9A-F]{4}$`
  (`devices/xiaomi/watches/MiBand10Coordinator.java:36`).
- No GATT services/characteristics apply to this device. (BLE UUIDs exist in
  the same codebase for *other* Xiaomi wearables — Mi Band 8, Redmi Watch
  3 Active, etc. — but are irrelevant here; not reproduced in this doc.)

## 2. Frame format

**[from source, untested]** Two independent, version-negotiated framing
schemes exist, referred to here as SPP-V1 and SPP-V2. Both carry a
serialized `xiaomi.Command` protobuf message (see §5, `proto/xiaomi.proto`)
as their payload.

### 2.1 Version negotiation (happens first, every connection)

1. Phone opens the RFCOMM socket and immediately sends a V1-framed
   `OPCODE_READ` request on channel `Version` (channel id `0`), then waits
   up to 5s (`XiaomiSppSupport.java:61-84`).
2. Response's first byte decides the session framing version: `>= 2` →
   upgrade to SPP-V2 for everything else on this connection; otherwise stay
   on SPP-V1 (`handleVersionPacket`, `XiaomiSppSupport.java:260-281`).
3. If SPP-V2: phone sends a `SessionConfig` `START_SESSION_REQUEST` packet
   (§2.3) before any other traffic (`XiaomiSppProtocolV2.java:134-143`).
4. Then, regardless of framing version, the auth handshake begins (§3)
   (`XiaomiSppSupport.java:278-280`, `XiaomiSppProtocolV2.java:109`).

**Inferred, not read directly:** which version the Band 10's firmware
actually reports is a live handshake response, not a static constant — M1
must observe and record it. `DailySummaryParser.java:140` calls activity-file
format version 5 "Mi Band 10 and later", which is weak circumstantial
evidence the SPP framing version is also ≥ 2, but that's a guess.

### 2.2 SPP-V1 packet (`XiaomiSppPacketV1.java`)

All integers little-endian unless noted.

```
[3 bytes  preamble: BA DC FE]
[1 byte   channel id, low nibble]   0=Version 1=ProtoRX 2=ProtoTX 3=Activity 4=Voice 5=Data 7=OTA
[1 byte   flags]                    0x80="flag", 0x40=needsResponse
[2 bytes  length]                   payload length INCLUDING the 3-byte sub-header below
[1 byte   opCode]                   0=READ 2=SEND
[1 byte   frame serial]             per-channel monotonic counter
[1 byte   dataType]                 0=PLAIN 1=ENCRYPTED 2=AUTH
[N bytes  payload]                  ciphertext if dataType=ENCRYPTED (§4.1)
[1 byte   epilogue: EF]
```

Channel/opcode/dataType constants: `XiaomiSppPacketV1.java:40-60`. Encode/
decode: `XiaomiSppPacketV1.java:235-330`. When `dataType=ENCRYPTED` and the
channel is `ProtoTX`/`ProtoRX` (protobuf command channel), a 2-byte LE
encryption counter is prepended to the ciphertext before framing
(`XiaomiSppPacketV1.java:304-313`); other encrypted channels fix the counter
at 0. No chunking at this framing layer — one packet, one `length` field,
`XiaomiSppProtocolV1.processPacket()` waits for that many bytes to be
buffered (`XiaomiSppProtocolV1.java:62-113`).

### 2.3 SPP-V2 packet (`XiaomiSppPacketV2.java`)

```
[2 bytes  preamble: A5 A5]
[1 byte   packet type, low nibble]  1=ACK 2=SessionConfig 3=Data
[1 byte   sequence number]
[2 bytes  payload length]
[2 bytes  CRC-16/ARC of payload]    poly 0x8005, init 0, no xorout, reflected
[N bytes  payload]
```

Encode/decode + checksum: `XiaomiSppPacketV2.java:413-514`.

- **SessionConfig** (type 2): opcodes `START_SESSION_REQUEST=1` /
  `RESPONSE=2` / `STOP_REQUEST=3` / `RESPONSE=4`; payload is a TLV list
  (1-byte key, 2-byte LE length, value). Keys seen: VERSION (3 bytes,
  `01 00 00`), MAX_PACKET_SIZE (2 bytes LE, official app sends `0xfc00` =
  64512), TX_WIN (2 bytes LE, `0x0020` = 32 frames), SEND_TIMEOUT (2 bytes
  LE, `0x2710` = 10000 ms) (`XiaomiSppPacketV2.java:87-254`).
- **Data** (type 3): payload = `[1 byte raw channel][1 byte opCode][body]`.
  Raw channel low nibble: `1`=Protobuf `2`=Data(plain) `5`=Activity. opCode:
  `1`=send-plaintext `2`=send-encrypted. Auth and Data channels are always
  sent plaintext; ProtobufCommand and Activity channels are sent encrypted
  (`getOpCodeForChannel`, `XiaomiSppPacketV2.java:336-348`). Encrypted body
  uses AES-CTR (§4.2).
- **ACK** (type 1): empty payload, acknowledges a sequence number. Every
  received Data packet must be ACKed with the same sequence number
  (`XiaomiSppProtocolV2.java:46-53`).
- RFCOMM has no MTU-driven chunking at this layer — reassembly is just
  "buffer bytes until the declared payload length is satisfied"
  (`XiaomiSppProtocolV2.processPacket()`).

## 3. Handshake / auth sequence

**[from source, untested]** Command type `1` in `xiaomi.Command`
(`XiaomiAuthService.java:64`); subtypes `CMD_SEND_USERID=5`, `CMD_NONCE=26`,
`CMD_AUTH=27` (lines 66-68). This sequence is the same regardless of SPP-V1
vs SPP-V2 framing — only how the bytes get chunked onto the wire differs.

1. **Phone → Watch:** load 16-byte `secretKey` (the "auth key", from account
   login — see `docs/TOKEN.md`, M2), generate a random 16-byte `phoneNonce`.
   Send `Command{type=1, subtype=26}` → `Auth.PhoneNonce{nonce=phoneNonce}`
   (`XiaomiAuthService.java:88-95, 244-256`).
2. **Watch → Phone:** `Command{type=1, subtype=26}` →
   `Auth.WatchNonce{nonce=watchNonce, hmac}` (`XiaomiAuthService.java:124-144`).
3. **Key derivation**, `computeAuthStep3Hmac()` (`XiaomiAuthService.java:258-290`):
   - `innerKey = HMAC-SHA256(key=phoneNonce||watchNonce, msg=secretKey)`
   - Expand: `block[0] = ""`; for `counter = 1, 2, 3...`:
     `block[counter] = HMAC-SHA256(key=innerKey, msg=block[counter-1] || "miwear-auth" || counter_byte)`
     until 64 bytes are produced.
   - Split the 64 bytes: `[0:16]=decryptionKey [16:32]=encryptionKey
     [32:36]=decryptionNonce [36:40]=encryptionNonce`. Remaining 24 bytes
     unused. (`XiaomiAuthService.java:200-205`.)
4. **Confirm:** phone computes
   `HMAC-SHA256(decryptionKey, watchNonce||phoneNonce)` and compares to the
   `hmac` the watch sent in step 2; mismatch aborts
   (`XiaomiAuthService.java:212-216`).
5. **Phone → Watch:** build `AuthDeviceInfo{unknown1=0, phoneApiLevel,
   phoneName=model, unknown3=224, region}` (see `proto/xiaomi.proto`),
   compute `encryptedNonces = HMAC-SHA256(encryptionKey,
   phoneNonce||watchNonce)`, encrypt the serialized `AuthDeviceInfo` with
   AES-CCM (§4.1) using packet counter 0. Send `Command{type=1, subtype=27}`
   → `Auth.AuthStep3{encryptedNonces, encryptedDeviceInfo}`
   (`XiaomiAuthService.java:218-241`).
6. **Watch → Phone:** `Command{type=1, subtype=27}` ack. On success, session
   encryption is considered live and subsequent traffic uses §4
   (`XiaomiAuthService.java:146-166`).

Auth key format accepted by Gadgetbridge: 32 hex chars (16 bytes), or
`0x`-prefixed 34-char hex (`XiaomiCoordinator.java:106-112`). The key itself
comes from the user's Xiaomi cloud account, out of band — that flow is M2's
job (`XiaomiCoordinator.getAuthHelp()` points at
`https://gadgetbridge.org/basics/pairing/huami-xiaomi-server/`,
`XiaomiCoordinator.java:114-118`).

## 4. Encryption

**[from source, untested]** Two schemes, matching the two framing versions.

### 4.1 SPP-V1: AES-128-CCM

- 12-byte nonce = `encryptionNonce (4B) || 00 00 00 00 (4B) || packetCounter (4B LE)`.
- Cipher: AES-CCM, 32-bit (4-byte) MAC tag, MAC verified on decrypt by
  default (`XiaomiCoordinator.checkDecryptionMac()` defaults `true`, not
  overridden for Band 10) (`XiaomiAuthService.java:172-196, 333-363`;
  `XiaomiCoordinator.java:644-646`).
- **Asymmetric counter:** encrypt (phone→watch) increments `packetCounter`
  per outgoing packet; decrypt (watch→phone) always uses counter `0`
  regardless of how many packets have been received
  (`XiaomiAuthService.java:185-196`). The outgoing counter travels on the
  wire as the 2-byte LE prefix described in §2.2.

### 4.2 SPP-V2: AES-128-CTR, key reused as IV

- `Cipher.getInstance("AES/CTR/NoPadding")`, called as
  `ctrCrypt(op, encryptionKey, encryptionKey, message)` — the same 16-byte
  session key from §3 step 3 is used as **both** the AES key and the CTR IV
  (`XiaomiAuthService.java:365-391`; flagged as unusual by an in-repo
  comment, "I wish I was kidding", at line 367/376).
- No MAC/AEAD at this layer. The only integrity check is the non-cryptographic
  CRC-16 in the SPP-V2 packet header (§2.3).

## 5. Command protobuf

`proto/xiaomi.proto` (vendored unmodified from Gadgetbridge) defines every
`Command` message and its nested payloads — auth, system/device info,
health/activity sync, notifications, weather, alarms, etc. Not reproduced
here; read the `.proto` file directly, it's the source of truth and stays in
sync with Phase 1 by construction (§ vendoring note in `proto/README.md`).

Relevant top-level command types referenced elsewhere in this doc:
- `type=1` Auth (§3)
- `type=2` System (device info, battery — M3 "read device info" milestone)
- `type=8` Health (activity fetch — §6, M4)

## 6. Activity record layout

**[from source, untested]** Reading this in full is M4's job, but recording
the shape now since it drives `activity.py`'s design.

### 6.1 File identifier (`XiaomiActivityFileId`)

7 bytes, little-endian, doubles as the request payload and the header
prefixed onto the fetched file:

```
[4 bytes  unix epoch seconds]
[1 byte   timezone, 15-min blocks]
[1 byte   format version]
[1 byte   flags]  bit7=type(0=ACTIVITY,1=SPORTS) bits1-6=subtype bits0-1=detailType(0=DETAILS,1=SUMMARY,2=GPS_TRACK)
```

(`activity/XiaomiActivityFileId.java:90-122, 227-268`.) Known ACTIVITY
subtypes: `DAILY=0x00`, `SLEEP_STAGES=0x03`, `MANUAL_SAMPLES=0x06`,
`SLEEP=0x08`.

### 6.2 Fetch protocol

Command type `8`, subtypes `CMD_ACTIVITY_FETCH_TODAY=1`,
`CMD_ACTIVITY_FETCH_PAST=2`, `CMD_ACTIVITY_FETCH_REQUEST=3`,
`CMD_ACTIVITY_FETCH_ACK=5` (`services/XiaomiHealthService.java:72-75`).

1. Phone requests today's, then past, file-id lists
   (`XiaomiHealthService.java:802-881`).
2. Watch replies with back-to-back 7-byte file IDs.
3. Phone requests each file id in priority order (summaries → details → GPS)
   via `CMD_ACTIVITY_FETCH_REQUEST` (`XiaomiHealthService.java:826-837`).
4. Watch streams the file over the Activity channel, app-level chunked as
   `[uint16 total][uint16 num][payload]`, reassembled by
   `XiaomiActivityFileFetcher.addChunk()`
   (`activity/XiaomiActivityFileFetcher.java:91-119`) — layered on top of the
   transport chunking in §2.
5. Reassembled file layout:
   ```
   [7 bytes  fileId]
   [1 byte   padding, expected 0]
   [N bytes  type-specific body — see below]
   [4 bytes  CRC32 LE, over all preceding bytes]
   ```
   (`XiaomiActivityFileFetcher.java:114-145`.)
6. Phone ACKs with `CMD_ACTIVITY_FETCH_ACK` unless
   `keepActivityDataOnDevice` is set.

### 6.3 Per-type body — high-level only, full field tables to be written in M4

- **Daily summary** (`DailySummaryParser.java`): one fixed-slot record.
  Version 5 ("Mi Band 10 and later", line 140) uses a 4-byte validity
  bitmap header + 32 slots (steps, calories, resting/max/min/avg HR + their
  timestamps, stress, standing-hours bitmap, SpO2 stats, training load,
  vitality). Older versions (3/4) use 3-byte header + 21 slots.
- **Daily details** (`DailyDetailsParser.java`): per-minute bit-packed
  stream (steps, calories, distance, HR, energy, +SpO2/stress from v3, +2
  undocumented fields from v4). **Gap: no version-5 branch exists** — an
  unrecognized version makes parsing fail outright (lines 52-67). Band 10
  daily-details records may need a new layout we don't have from Gadgetbridge
  at all; M4 needs to determine this empirically.
- **Sleep stages** (`SleepStagesParser.java`, version 2 only): fixed summary
  header (durations, bed/wake time) + a stream of
  `[int32 timestamp][uint8 phase]` phase-change events.
- **Sleep details** (`SleepDetailsParser.java`, versions 1-5): most complex
  format — summary header, three optional HR/SpO2/snore sample sub-streams
  (present but not decoded per-sample in Gadgetbridge itself), then a
  magic-framed (`0xFFFCFAFB`) event stream with typed sub-records (RR
  intervals, summary, per-stage durations).
- **Manual samples** (`ManualSamplesParser.java`, version 2 only): flat
  `[int32 timestamp][uint8 type][value]` stream for spot-check HR/SpO2/
  stress/temperature readings; unrecognized type aborts the rest of the
  file; `value==0` means "no reading", not a real zero.
- **Calories** has no dedicated file — it's fields inside daily-summary and
  daily-details.

## 7. Band 10 specifics recap

- `ConnectionType.BT_CLASSIC`, not BLE (§0).
- Marked `isExperimental()=true` in Gadgetbridge — expect rough edges.
- `checkDecryptionMac()` not overridden → AES-CCM MAC verification enabled
  for the SPP-V1 path (§4.1).
- Activity file format version 5 confirmed (via comment) for daily-summary;
  likely but not confirmed for sleep-details and daily-details.

## 1a. Discovery (Windows, WinRT — not from Gadgetbridge source)

**[from WinRT platform knowledge, untested]** Android's Bluetooth classic
discovery has no Windows equivalent to read from Gadgetbridge, so this part
is new: `src/miband/transport.py::scan()` uses WinRT device enumeration
directly (`winrt-Windows.Devices.Enumeration`,
`winrt-Windows.Devices.Bluetooth`), not `bleak` — bleak's WinRT backend only
covers BLE advertisement/GATT APIs, not classic-BT AEP enumeration.

- Filters `DeviceInformation` via the Bluetooth-Classic Association Endpoint
  Provider protocol id `{e0cbf06c-cd8b-4647-bb8a-263b43f0f974}` (from
  Microsoft's own device-watcher samples, not verified against this specific
  device yet).
- Resolves each match's MAC via `BluetoothDevice.from_id_async(...)
  .bluetooth_address`.
- Device name filter: `^Xiaomi Smart Band 10 [0-9A-F]{4}$` (same regex
  Gadgetbridge uses, `MiBand10Coordinator.java:36`).
- Does **not** attempt pairing or an RFCOMM connection — Windows manages
  classic-BT Secure Simple Pairing (PIN/passkey) at the OS level, and that
  handshake is out of scope until M3.

**M1 run:** on native Windows, `uv run miband scan` (10s window by default,
`--timeout` to change it). Success = your Band 10 listed with the `<--`
marker and a MAC address. If nothing shows up, the AEP selector GUID above
is the first thing to question — report back exactly what `scan` prints
(or errors with) so this section can be corrected against reality.

## Open questions for M1+

- Confirm SPP framing version (V1 vs V2) the real device negotiates.
- Confirm whether daily-details activity files actually arrive at version 5,
  and if so reverse-engineer the layout Gadgetbridge doesn't handle.
- Confirm GATT is truly absent (no fallback BLE service exposed) when
  scanning — expected per §0, but M1 should verify empirically.
