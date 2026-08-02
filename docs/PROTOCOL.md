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

**Correction (M1, verified on hardware via `ios/MFiCheck`):** the above is
Android/Gadgetbridge's reality only. The device *also* advertises and serves
a full BLE GATT interface in parallel — see §0a. Gadgetbridge never needed
it because Android can open an arbitrary classic-BT RFCOMM socket from any
app; iOS categorically cannot (`CoreBluetooth` is BLE-only, and classic-BT/
RFCOMM access from a non-jailbroken app requires MFi certification via
`ExternalAccessory`, which this reverse-engineered protocol doesn't have —
confirmed empty `EAAccessoryManager.connectedAccessories` on real hardware).
**The Phase 1 Swift/iOS implementation should target the BLE GATT interface
in §0a, not classic RFCOMM.**

## 0a. BLE GATT surface (iOS path) — verified on hardware

**[verified, `ios/MFiCheck`]** Confirmed via a throwaway SwiftUI/CoreBluetooth
diagnostic app (`ios/MFiCheck/`, not part of the AGPL Python CLI, built
unsigned via `.github/workflows/mficheck-ipa.yml` and sideloaded).

- Advertises with local name matching the same regex as classic-BT discovery
  (§1), e.g. `Xiaomi Smart Band 10 E817`. The advertisement payload itself
  carries **no service UUID list and no manufacturer data** — only the name.
  Advertising window is narrow and appears tied to the official Xiaomi app
  actively syncing/refreshing the device, not constant (same discoverability
  quirk observed on the Windows classic-BT side, §1a). Practical consequence:
  a passive scan often sees nothing; triggering a sync from the Xiaomi
  Wear/Mi Fitness app while scanning is what surfaces it.
- **Retracted:** an earlier note here claimed the Band only holds one active
  BLE central connection at a time, based on `ios/Manumit`'s notify channel
  going silent right after our own `tx` in
  `fixtures/session-20260802-114424.jsonl`. Reproduced again with Mi Fitness
  fully force-quit (not just backgrounded) and still silent, which rules that
  theory out -- see the sequence-numbering bug below instead, which is the
  real explanation for that fixture.
- Once connected, GATT table observed:
  - **`FE95`** — SIG-registered to Xiaomi Inc. (MiBeacon; verified against
    the official Bluetooth SIG assigned-numbers registry, not from memory).
    Characteristics `0050` `[read]`, `005E` `[writeNoResp, notify]`, `005F`
    `[writeNoResp, notify]`. Shape suggests a command/response pair (write
    request, notify response) — likely Xiaomi's standard Mi-ecosystem
    binding/provisioning channel, shared across many Xiaomi BLE products,
    not Band-10-specific.
  - **`FDAB`** — not a SIG-registered UUID (vendor-custom). Characteristics
    `0001` `[read]`, `0002` `[writeNoResp, notify]`, `0003` `[writeNoResp,
    notify]`. Same read + write/notify-pair shape as `FE95`. Best guess:
    the actual Band 10 control/data channel — payload format not yet
    reverse-engineered.
  - **`180F`** Battery Service → `2A19` Battery Level `[read, notify]`
    (standard GATT, no reverse-engineering needed).
  - **`180A`** Device Information Service → `2A50` PnP ID `[read]`
    (standard GATT).
  - **`180D`** Heart Rate Service → `2A37` Heart Rate Measurement
    `[notify]` (standard GATT — live heart rate is readable with zero
    proprietary protocol work).
- **`FDAB` blind-probe result (`ios/MFiCheck`, 2026-08-01):**
  - Reading `0001` returns a single byte: `01`. Too short to be a
    protobuf/framed payload — looks like a status/capability flag, not a
    data channel by itself.
  - Subscribing notify on `0002`/`0003` succeeds (`isNotifying=true`), but
    writing `writeNoResp` with an empty payload or a single `0x00` byte to
    either characteristic produces **no notify response at all** — no ACK,
    no error frame, nothing. Repeated twice, same result both times.
  - Conclusion: `FDAB` doesn't echo/ACK arbitrary bytes, so it isn't a
    dumb passthrough. Either it silently drops anything that isn't a
    validly-framed packet (consistent with the SPP-style framing in §2 —
    a bad preamble/CRC would just be discarded, not answered), or it
    requires a prior handshake/auth step (mirroring §3's auth handshake
    on the classic-BT side) before it responds to anything on `0002`/
    `0003`.
- **SPP-V1-framed probe result (`ios/MFiCheck`, 2026-08-01):** wrote the
  literal first packet Gadgetbridge sends on classic-BT RFCOMM (§2.1/§2.2:
  `BA DC FE 00 40 03 00 00 00 00 EF` — preamble, channel 0/Version,
  `needsResponse` flag, `OPCODE_READ`, plaintext, `EF` epilogue) to both
  `0002` and `0003`. **Still zero response**, same as the blind
  empty/null-byte probe. Rules out "any syntactically-valid SPP-V1 packet
  wakes it up" — a correctly-framed, real Gadgetbridge packet got exactly
  the same silence as garbage bytes.
- **Correction, from source (2026-08-01):** `FDAB` was the wrong channel —
  Gadgetbridge's own tree already has a working BLE transport for other
  Xiaomi devices, and it targets `FE95`, not `FDAB`. `FDAB` doesn't appear
  anywhere in Gadgetbridge; blind probing it was always going to be
  silence. Found by reading `reference/Gadgetbridge` source (no Android/
  live-app sniffing needed — the answer was already checked into the repo
  we're deriving from):
  - `XiaomiUuids.java:29-31` (`BLE_V2_SERVICE_UUID`/`_RX_UUID`/`_TX_UUID`,
    comment "Mi Band 9 Active"): service `FE95`, RX characteristic `005E`,
    TX characteristic `005F` — an **exact match** for two of this device's
    three `FE95` characteristics (`0050` is extra/unexplained).
  - `XiaomiBleSupport.java` + `XiaomiBleProtocolV2.java`: this is a real,
    working Gadgetbridge BLE transport (`XiaomiBleProtocolV2`, used when
    `XiaomiBleProtocolV1` — the older `0051`-`0055` scheme, §0a below —
    doesn't match). It reuses the **SPP-V2 packet framing from §2.3**
    (`A5 A5` preamble, not SPP-V1's `BA DC FE`) verbatim over BLE: notify
    enabled on `005E`, writes chunked onto `005F`
    (`XiaomiBleProtocolV2.java:66-93, 351-353`).
  - First packet sent, before anything else: a `SessionConfig`
    `START_SESSION_REQUEST` (packet type 2, not a Version-channel read),
    payload `01 01 03 00 01 00 00 02 02 00 00 FC 03 02 00 20 00 04 02 00
    10 27` (opcode + VERSION/MAX_PACKET_SIZE/TX_WIN/SEND_TIMEOUT TLVs,
    `XiaomiSppPacketV2.java:133-158` — "from packet dump of official app").
    Checksum is CRC-16/ARC (poly `0x8005`, init 0, reflected in/out, no
    xorout) over the payload only (`XiaomiSppPacketV2.java:413-425`).
  - This means the earlier `BA DC FE`-framed probe (previous entry) was
    doubly wrong: wrong characteristic (`FDAB` vs `FE95`) *and* wrong
    framing version (SPP-V1 vs SPP-V2) *and* wrong first message
    (Version-read vs StartSessionRequest).
  - `XiaomiUuids.java:33-46` also documents an older **BLE-V1** scheme
    (`FE95` again, but characteristics `0051`/`0052`/`0053`/`0055`, used by
    Mi Band 8/Redmi Watch 3 Active/etc., encrypted from the start) — doesn't
    match this device's characteristic list at all, so BLE-V2 is the one to
    try.
- **[verified on hardware, `ios/MFiCheck`, 2026-08-01]** BLE-V2/SPP-V2
  confirmed correct, byte-for-byte, no guessing left. Raw capture:
  `fixtures/session-20260801-fe95-ble-v2.jsonl`.
  - Sent the exact `StartSessionRequest` packet from the previous entry to
    `005F`. Got back a real `SessionConfig` `START_SESSION_RESPONSE` (opcode
    `02`) on `005E`: `VERSION=03 00 41`, `MAX_PACKET_SIZE=0x8000` (32768,
    not the requested `0xfc00`), `TX_WIN=3` (not the requested `0x0020`),
    `SEND_TIMEOUT=0x3E80` (16000ms, not the requested `0x2710`) — device
    negotiates its own values back, doesn't just echo the request.
  - **Unexpected, and useful:** the *instant* notify was enabled on `005E`
    — before any request of ours went out — the band started streaming
    fully-formed SPP-V2 frames unprompted: ACKs, an unencrypted `Command
    {type=1, subtype=26}` → `Auth.WatchNonce` (protobuf `08 01 10 1A 1A
    37 ...`, matches §3 step 2 exactly, live confirmation of that
    protobuf shape), and ~25 `Data`/`ProtobufCommand`-channel packets with
    `opCode=ENCRYPTED` (can't decode payload without session keys, but the
    outer framing — channel nibble, opcode, SPP-V2 header — matches
    §2.3/§5 predictions exactly). Working theory: the band was already in
    an active, authenticated BLE session with something else (the official
    Mi Fitness/Xiaomi Wear app, likely backgrounded on the same iPhone or
    paired previously) at the GATT-firmware level, and simply fans out
    `005E` notifications to *every* subscribed central regardless of which
    one it authenticated with — i.e. **the notify characteristic isn't
    session-scoped**, any app that subscribes gets to watch the live
    encrypted traffic. That's how we captured a real, in-the-wild Auth
    exchange without writing a single byte ourselves.
  - Practical consequence for Phase 1: passively subscribing to `005E` and
    logging is a legitimate, zero-risk way to harvest more real traffic
    (including future cleartext Auth packets) just by having the official
    app active — useful for building up more fixtures before attempting
    our own handshake.
- **[verified, `fixtures/session-20260801-235708.jsonl`, 2026-08-01]**
  Second passive-listen capture, this time via `ios/MFiCheck`'s automatic
  fixture logging (real monotonic timestamps, not reconstructed). Two new
  confirmations:
  - **raw_channel=5 (Activity) seen live for the first time** (records
    seq 10-13, `opCode=ENCRYPTED`) — previously only `[from source,
    untested]` in §2.3's channel table. Body stays opaque without session
    keys, as expected; outer framing decodes cleanly
    (`tests/test_protocol.py::test_decode_v2_activity_channel`).
  - **Real BLE-notify fragmentation of a single SPP-V2 payload**, confirming
    §2.3's "buffer bytes across reads" requirement isn't just theoretical:
    record seq 9 declares a 599-byte payload, but the first `005E` notify
    only delivers 487 of them (495 bytes total with the 8-byte header); the
    remaining 112 bytes arrive as a second, separate notify event with no
    header of its own. `decode_v2` correctly returns `None` on the first
    chunk and completes once both are concatenated
    (`tests/test_protocol.py::test_decode_v2_incomplete_until_second_ble_notify_chunk`).

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
- No GATT services/characteristics apply to *this transport* (Gadgetbridge's
  Android/classic-BT path). The device does have a separate BLE GATT
  interface used by the iOS path — see §0a, not covered by Gadgetbridge
  since Android never needs it.

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
   **[verified, `ios/Manumit`, 2026-08-02, `fixtures/session-20260802-114424.jsonl`]**
   SPP-V2 packet sequence numbers for the Data channel and for SessionConfig
   are **separate counters**, not one shared one
   (`XiaomiBleProtocolV2.java:90` hardcodes `SessionConfigPacket` sequence to
   literal `0`; the `Data`-packet counter (`:46,344`) is distinct and only
   increments on `encodePacket()`, i.e. per Data send) — so the first Data
   packet (this PhoneNonce) must go out with sequence `0`, not whatever
   comes after the SessionConfig request's own sequence. Getting this wrong
   (sharing one counter, sending PhoneNonce as sequence `1`) produced a
   silent failure on real hardware: no ACK, no WatchNonce, no error, stuck
   forever on "waiting for watch nonce" — the watch just drops an
   out-of-order Data packet rather than rejecting it.
2. **Watch → Phone:** `Command{type=1, subtype=26}` →
   `Auth.WatchNonce{nonce=watchNonce, hmac}` (`XiaomiAuthService.java:124-144`).
   **[verified, offline decode of `fixtures/session-20260801-fe95-ble-v2.jsonl`
   seq 6, 2026-08-01]** Decoded the captured plaintext Data packet
   (`raw_channel=1` Protobuf, `opCode=1` PLAINTEXT) with `proto/xiaomi.proto`
   compiled via `protobuf`/`grpcio-tools` (no guessing, no fixture edits —
   this is the exact frame the band sent). `Command.type=1`,
   `Command.subtype=26`, `Command.auth.watchNonce` present with a 16-byte
   `nonce` (`1570e75f39bb2d0033b11178e2715141`) and a 32-byte `hmac`
   (`b69e067177207892e98d6e6030ff578a069948f067f81d9b59426c94df196969`) —
   field tags, lengths and nested-message shape match this spec byte for
   byte. Values are single-use handshake nonces/HMACs from a session we're
   not party to, not long-term secrets, so kept in the fixture and quoted
   here. Two of the shortest `opCode=ENCRYPTED` Data packets in the same
   capture (seq 11/12) were also decoded at the outer-framing level only:
   `raw_channel=1`, `opCode=2`, 7-byte encrypted body — matches §2.3's Data
   packet structure exactly; body stays opaque without the session key from
   §3 step 3, as expected, and was not attacked.
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

### 5.0 Non-auth commands ride the same raw channel as Auth

**[verified, `ios/Manumit`, 2026-08-02, `fixtures/session-20260802-125630.jsonl`]**
Once authenticated, System/Health/etc. commands are *not* a different
`raw channel` from Auth — both are `raw_channel=1` (`CHANNEL_PROTOBUF`,
`XiaomiSppPacketV2.java:258`); only the opCode differs (`1`=plaintext for
Auth, `2`=encrypted §4.2 for everything else, `getOpCodeForChannel`,
`XiaomiSppPacketV2.java:336-348`). `raw_channel=2` is `CHANNEL_DATA`, an
unrelated always-plaintext channel, not "System".

**System/Battery GET** (type=2, subtype=1): request is a bare
`Command{type=2, subtype=1}` with no other field set — matches
`XiaomiSupport.sendCommand(taskName, type, subtype)`
(`XiaomiSupport.java:423-431`), which every `CMD_*_GET` in
`XiaomiSystemService.java` (lines 107-141) uses. Confirmed byte-for-byte on
hardware: sent as 4-byte plaintext `08 02 10 01`, encrypted to `12 71 45 E4`.
Response is `Command{type=2, subtype=1, system=System{power=Power{battery=
Battery{level, state, lastCharge}}}}` (`handleBattery`,
`XiaomiSystemService.java:380-403`) — decrypted on hardware to `08 02 10 01
22 12 12 10 0A 0E 08 63 10 02 1A 08 08 03 10 A5 E7 B6 D3 06`, decoding to
`level=99 state=2 lastCharge={state=3, timestampSeconds=1785574309}` (=
2026-08-01 08:51 UTC, a day before capture — a plausible last-charge time,
not garbage). `level`/`state` are the only fields `ios/Manumit` decodes so
far; `lastCharge` present on the wire but unparsed by the app.

### 5.1 Full command catalog

**[from source, untested]** Every `COMMAND_TYPE` Gadgetbridge's Xiaomi
implementation dispatches on, and the `CMD_` subtypes each service handles.
One `AbstractXiaomiService` subclass per row, all under
`service/devices/xiaomi/services/` unless noted. This is the complete
command surface as reverse-engineered from Gadgetbridge — richer than what
`docs/`'s own firmware exposes as its "official" MIoT spec (§8.3).

| type | Service | Subtypes (`CMD_*`, decimal) | Citation |
|---|---|---|---|
| 1 | Auth | `SEND_USERID=5` `NONCE=26` `AUTH=27` | `XiaomiAuthService.java:66-68` (§3) |
| 2 | System | `BATTERY=1` `DEVICE_INFO=2` `CLOCK=3` `FIRMWARE_INSTALL=5` `LANGUAGE=6` `CAMERA_REMOTE_GET=7` `CAMERA_REMOTE_SET=8` `PASSWORD_GET=9` `MISC_SETTING_GET=14` `MISC_SETTING_SET=15` `FIND_PHONE=17` `FIND_WATCH=18` `PASSWORD_SET=21` `DND_MODE_SET=23` `DISPLAY_ITEMS_GET=29` `DISPLAY_ITEMS_SET=30` `WORKOUT_TYPES_GET=39` `MISC_SETTING_SET_FROM_BAND=42` `SILENT_MODE_GET=43` `SILENT_MODE_SET_FROM_PHONE=44` `SILENT_MODE_SET_FROM_WATCH=45` `WIDGET_SCREENS_GET=51` `WIDGET_SCREENS_SET=52` `WIDGET_PARTS_GET=53` `DEVICE_STATE_GET=78` `DEVICE_STATE=79` | `XiaomiSystemService.java:76-101` |
| 4 | Watchface | `LIST=0` `SET=1` `DELETE=2` `INSTALL=4` | `XiaomiWatchfaceService.java:43-46` |
| 7 | Notification | `SEND=0` `DISMISS=1` `CALL_REJECT=2` `CALL_IGNORE=5` `SCREEN_ON_ON_NOTIFICATIONS_GET=6` `SCREEN_ON_ON_NOTIFICATIONS_SET=7` `OPEN_ON_PHONE=8` `CANNED_MESSAGES_GET=9` `CANNED_MESSAGES_SET=12` `CALL_REPLY_SEND=13` `CALL_REPLY_ACK=14` `NOTIFICATION_ICON_REQUEST=15` `NOTIFICATION_ICON_QUERY=16` | `XiaomiNotificationService.java:65-77` |
| 8 | Health | `SET_USER_INFO=0` `ACTIVITY_FETCH_TODAY=1` `ACTIVITY_FETCH_PAST=2` `ACTIVITY_FETCH_REQUEST=3` `ACTIVITY_FETCH_ACK=5` `CONFIG_SPO2_GET=8` `CONFIG_SPO2_SET=9` `CONFIG_HEART_RATE_GET=10` `CONFIG_HEART_RATE_SET=11` `CONFIG_STANDING_REMINDER_GET=12` `CONFIG_STANDING_REMINDER_SET=13` `CONFIG_STRESS_GET=14` `CONFIG_STRESS_SET=15` `CONFIG_GOAL_NOTIFICATION_GET=21` `CONFIG_GOAL_NOTIFICATION_SET=22` `WORKOUT_WATCH_STATUS=26` `WORKOUT_WATCH_OPEN=30` `CONFIG_VITALITY_SCORE_GET=35` `CONFIG_VITALITY_SCORE_SET=36` `CONFIG_GOALS_GET=42` `CONFIG_GOALS_SET=43` `REALTIME_STATS_START=45` `REALTIME_STATS_STOP=46` `REALTIME_STATS_EVENT=47` `WORKOUT_LOCATION=48` | `XiaomiHealthService.java:71-95` (§6.2) |
| 10 | Weather | `SET_CURRENT_WEATHER=0` `UPDATE_DAILY_FORECAST=1` `UPDATE_HOURLY_FORECAST=2` `REQUEST_CONDITIONS_FOR_LOCATION=3` `GET_LOCATIONS=5` `SET_LOCATIONS=6` `ADD_LOCATION=7` `REMOVE_LOCATIONS=8` `GET_WEATHER_PREFS=9` `SET_WEATHER_PREFS=10` | `XiaomiWeatherService.java:57-66` |
| 12 | Calendar | `CALENDAR_SET=1` | `XiaomiCalendarService.java:41,43` |
| 17 | Schedule | `ALARMS_GET=0` `ALARMS_CREATE=1` `ALARMS_EDIT=2` `ALARMS_DELETE=4` `SLEEP_MODE_GET=8` `SLEEP_MODE_SET=9` `WORLD_CLOCKS_GET=10` `WORLD_CLOCKS_SET=11` `REMINDERS_GET=14` `REMINDERS_CREATE=15` `REMINDERS_EDIT=17` `REMINDERS_DELETE=18` | `XiaomiScheduleService.java:60-71` |
| 18 | Music | `MUSIC_GET=0` `MUSIC_SEND=1` `MUSIC_BUTTON=2` (button sub-values: play/pause/previous/next/volume) | `XiaomiMusicService.java:36-38` |
| 20 | **Rpk (QuickApps)** | `RPK_LIST=0` `RPK_INSTALL/SET=1` `RPK_INSTALLED=2` `RPK_DELETE=3` | `XiaomiRpkService.java:45-49` (§8) |
| 21 | Phonebook | `GET_CONTACT=2` `GET_CONTACT_RESPONSE=3` `ADD_CONTACT_LIST=5` `SET_CONTACT_LIST=7` | `XiaomiPhonebookService.java:43-46` |
| 22 | DataUpload | `UPLOAD_START=0` | `XiaomiDataUploadService.java:40-42` |

Not every subtype here is necessarily meaningful for the Band 10 specifically
— this is Gadgetbridge's shared Xiaomi implementation, used across several
device models. Treat as "commands the protocol *supports*", to be narrowed
down as M1+ milestones confirm what this specific band actually accepts.

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

## 8. App management (QuickApps / RPK)

**[from firmware analysis + source, untested]** Cross-checked against an
actual OTA image, not just Gadgetbridge source: `upd_miwear.watch.o66gl.zip`
(`ota.json`: `magic_string=o66`, `sw_version=3.2.7`), a local reference
artifact — not committed to this repo, same treatment as
`/reference/Gadgetbridge`. It's a Xiaomi Vela OS (NuttX) OTA package: a
handful of raw MCU binaries (`vela_ap.bin` = main firmware, `vela_ota.bin` =
bootloader) plus several `rom1fs` filesystem images (`app.bin`,
`quickapp.bin`, `vendor.bin`, `system.bin`, `misc.bin`, `recovery.bin`,
`watchface.bin`, `font.bin`, `i18n.bin`). `rom1fs` layout: 16-byte header
(`-rom1fs-` + size + checksum) + null-terminated volume name, then
16-byte-aligned file headers (`next|info|size|checksum` as big-endian
`uint32`s + null-terminated name); low 4 bits of `next` encode
type(3 bits)+executable-flag(1 bit), the rest is the next entry's absolute
offset. For directories, `info` is the child listing's offset; for plain
files, `info` is unused — data starts right after the name, padded to 16
bytes.

**Two different kinds of "app" exist, and only one is deletable over the
protocol:**

- **Built-in native apps** — alarm, sports, weather, compass, sleep,
  flashlight, etc. 50+ top-level directories in `app.bin` (icons/widgets/
  launcher assets per app), with the executable code itself compiled into
  `vela_ap.bin`. No delete/uninstall command exists anywhere in
  Gadgetbridge's Xiaomi implementation for these — they ship as part of the
  firmware image and can only change via a full OTA reflash (`type=2`
  `CMD_FIRMWARE_INSTALL=5`, §5.1). **Not removable from a companion app.**
- **QuickApps** — `.rpk` packages, managed by command `type=20` (§5.1):
  `RPK_LIST` / `RPK_INSTALL` / `RPK_DELETE` (`XiaomiRpkService.java:43-49`).
  `deleteRpk()` sends `Command{type=20, subtype=3}` →
  `Rpk.RpkInfoList{id=packageName, sha}`, no response expected — the phone
  just re-requests the list immediately after
  (`XiaomiRpkService.java:104-124`). `installRpk()` sends
  `Command{type=20, subtype=1}` → `Rpk.RpkInfo{id, versionCode, size}`, then
  streams the `.rpk` bytes over the data-upload channel (`type=22`,
  §5.1) once the watch acks (`XiaomiRpkService.java:132-149`).

This build's `quickapp.bin` contains exactly one bundled QuickApp,
`com.xiaomi.smarthome.watch` v1.0.1 (415599-byte `.rpk`, a zip — `PK\x03\x04`
magic, `META-INF/` inside — presumably signed). `/rpk_info.json` inside that
same image additionally lists QuickApps the platform *supports* but doesn't
ship in this build: `com.baidu.BaiduMap` (Baidu Maps), `com.vela.calculator`,
`com.kugou.xiaomi` (KuGou Music), `com.tencent.wechatrtos` (WeChat),
`com.netease.vela` (NetEase Cloud Music) — installable the same way via
`RPK_INSTALL`.

**Practical answer:** yes, QuickApps can be listed/installed/deleted from a
companion app (§5.1 `type=20`); no, the built-in system apps cannot.

### 8.1 Device spec (MIoT)

`misc.bin:/spec/spec_config.json` (30359 bytes) is the device's official
MIoT cloud-spec: `type: urn:miot-spec-v2:device:watch:0000A07C:miwear-o66nfc:1`
— `o66nfc` matches the OTA package's `o66gl` codename, confirming this spec
belongs to this exact device. 8 services: device-information, vital-signs,
motion-data, battery, sleep, device-status, vibration,
wear-car-interconnect — each with typed `properties`/`actions`/`events`
(iid-addressed). This is the subset Xiaomi exposes to its own cloud
integration; it's **not** a substitute for §5.1 — the local RFCOMM protocol
exposes far more (QuickApp management, watchfaces, phonebook, calendar, full
health config) than this cloud spec covers.

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
- Confirm `RPK_LIST` (§8) actually returns `com.xiaomi.smarthome.watch` on
  the real band, and that `RPK_DELETE` is accepted (not just for
  Gadgetbridge's supported device set — this app is a factory default,
  which some vendors block from deletion despite the generic command
  existing).
