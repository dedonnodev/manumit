# Xiaomi cloud auth-key retrieval

Status: **M2**, `[from source, untested against a real Windows run of the
CLI]` — the HTTP flow below matches
`vendor/xiaomi_cloud/token_extractor.py` (MIT, vendored unmodified,
`PiotrMachowski/Xiaomi-cloud-tokens-extractor`) as read, not as observed on
the wire. Describes the password + email-2FA path in detail (what
`miband auth-key` drives); QR-code login is a separate path, noted briefly
at the end.

This exists to be ported to Swift for Phase 1 — the iOS app needs its own
login flow, it can't shell out to a Python script.

## 1. Login (get `ssecurity` + `userId` + `serviceToken`)

Session state carried across all three steps: a cookie jar, plus a random
per-run `deviceId` (6 lowercase letters) sent as a cookie, and a random
`agent` User-Agent string of the form
`{18 lowercase letters}-{13 uppercase letters E-Z} APP/com.xiaomi.mihome APPV/10.5.201`
(`generate_agent`/`generate_device_id`, `token_extractor.py:177-187`).

### 1.1 `GET https://account.xiaomi.com/pass/serviceLogin?sid=xiaomiio&_json=true`

Cookies: `userId=<username>`. Response body is JSON prefixed with
`&&&START&&&` (strip that prefix before parsing —
`XiaomiCloudConnector.to_json`, line 220-221). Two possible shapes:
- `{"_sign": "..."}` — first-time login, need step 1.2 with this sign.
- `{"ssecurity", "userId", "cUserId", "passToken", "location", "code"}` —
  already-authenticated session (cookie reuse); skip straight to 1.3 if
  `location` is set and no service token yet.

(`login_step_1`, lines 281-308.)

### 1.2 `POST https://account.xiaomi.com/pass/serviceLoginAuth2`

Query params (yes, params not body — `requests.post(..., params=fields)`):
```
sid=xiaomiio
hash=<MD5(password), hex, UPPERCASE>
callback=https://sts.api.io.mi.com/sts
qs=%3Fsid%3Dxiaomiio%26_json%3Dtrue
user=<username>
_sign=<from step 1.1>
_json=true
```
`allow_redirects=False`. Response body, JSON (strip `&&&START&&&` prefix as
above). Branches (`login_step_2`, lines 310-375):

- **`captchaUrl` present:** GET that URL (relative → prefix
  `https://account.xiaomi.com`) to fetch a captcha image, show it to the
  user, retry the same POST with `captCode=<solution>` added to `fields`.
  `json_resp["code"] == 87001` on retry = wrong captcha.
- **`ssecurity` present, length > 4:** success. Capture `ssecurity`,
  `userId`, `cUserId`, `passToken`, `location`, `code`.
- **`notificationUrl` present (no ssecurity):** email 2FA required, go to
  §1.2a.
- Otherwise: login failed (bad credentials).

### 1.2a Email 2FA flow (only when triggered above)

This is the fiddliest part — six sequential requests
(`do_2fa_email_flow`, lines 415-597):

1. `GET <notificationUrl>` (the "authStart" URL from step 1.2) — establishes
   session state server-side, response not otherwise used.
2. `GET https://account.xiaomi.com/identity/list` with params
   `sid=xiaomiio&context=<context from notificationUrl's query string>&_locale=en_US`
   — lists identity-verification options.
3. `POST https://account.xiaomi.com/identity/auth/sendEmailTicket`,
   params `_dc=<epoch ms>&sid=xiaomiio&context=<context>&mask=0&_locale=en_US`,
   form body `retry=0&icode=&_json=true&ick=<ick cookie value, or empty>`
   — triggers the verification email.
4. User reads the code from email, supplied interactively.
5. `POST https://account.xiaomi.com/identity/auth/verifyEmail`, params
   `_flag=8&_json=true&sid=xiaomiio&context=<context>&mask=0&_locale=en_US`,
   form body `_flag=8&ticket=<code>&trust=false&_json=true&ick=<ick cookie>`.
   Response JSON's `location` field (or a fallback: `Location` header, or a
   regex `https://account\.xiaomi\.com/identity/result/check\?...` scraped
   from the body, or as a last resort a direct
   `GET /identity/result/check?sid=xiaomiio&context=<context>&_locale=en_US`
   with `allow_redirects=False` to read its `Location` header) gives the
   next hop.
6. If that hop is `identity/result/check`, `GET` it with
   `allow_redirects=False` and read the `Location` header for the real
   finish URL. `GET` that finish URL, again `allow_redirects=False`. The
   response carries an **`extension-pragma` response header** containing
   JSON `{"ssecurity": "...", "psecurity": "..."}` — that's where
   `ssecurity` comes from on this path. (Some servers 200 with an HTML
   "Tips" interstitial first; if so, repeat the same GET once more.)
7. Find the STS redirect — either the `Location` header, or a
   `https://sts.api.io.mi.com/sts...` URL scraped out of the body — and
   `GET` it with redirects followed. This sets a `serviceToken` cookie on
   domain `.sts.api.io.mi.com`.
8. Copy that `serviceToken` cookie onto domains `.api.io.mi.com`,
   `.io.mi.com`, `.mi.com` (both as `serviceToken` and
   `yetAnotherServiceToken`) so later API calls see it
   (`install_service_token_cookies`, lines 599-602).

### 1.3 `GET <location>` (password path only, skipped if 2FA path already set serviceToken)

No special params. Response's `Set-Cookie: serviceToken=...` is what later
API calls authenticate with (`login_step_3`, lines 377-387).

## 2. Encrypted API calls

Every subsequent call goes through the same envelope
(`execute_api_call_encrypted`, lines 131-157):

**Headers:**
```
Accept-Encoding: identity
User-Agent: <the same generated agent from login>
Content-Type: application/x-www-form-urlencoded
x-xiaomi-protocal-flag-cli: PROTOCAL-HTTP2
MIOT-ENCRYPT-ALGORITHM: ENCRYPT-RC4
```

**Cookies:** `userId`, `yetAnotherServiceToken`, `serviceToken` (all =
serviceToken value), `locale=en_GB`, `timezone=GMT+02:00`, `is_daylight=1`,
`dst_offset=3600000`, `channel=MI_APP_STORE`.

**Request signing/encryption** (`generate_enc_params`, lines 207-217; all
base64 unless noted):

1. `nonce = random 8 bytes || big_endian_uint32(floor(now_ms / 60000))`,
   base64-encoded (`generate_nonce`, lines 172-175).
2. `signed_nonce = base64(SHA256(base64_decode(ssecurity) || base64_decode(nonce)))`
   (`signed_nonce`, lines 163-165) — this is the actual RC4 key/HMAC key for
   everything below, derived fresh per request from the account's
   `ssecurity` and this request's `nonce`.
3. Start with `params = {"data": "<json string>"}` (the endpoint-specific
   payload, see §3).
4. `params["rc4_hash__"] = base64(SHA1(signature_string))` where
   `signature_string = "&".join([METHOD, url_path_after_domain_with_/app/_stripped, *["k=v" for k,v in params.items()], signed_nonce])`
   — computed once with the plaintext `data` value
   (`generate_enc_signature`, lines 198-205; note `url.split("com")[1]`
   grabs everything after the first `com` in the hostname, then
   `.replace("/app/", "/")`).
5. RC4-encrypt every value in `params` (including the just-added
   `rc4_hash__`) with key = `signed_nonce`:
   `RC4.new(base64_decode(signed_nonce))`, discard the cipher's first 1024
   generated bytes (`r.encrypt(bytes(1024))`, i.e. RC4-drop[1024]), *then*
   encrypt the payload and base64 it (`encrypt_rc4`, lines 223-227).
6. Recompute `signature = base64(SHA1(signature_string))` the same way as
   step 4 but now over the RC4-encrypted `params`.
7. Final form-encoded POST body:
   `{...rc4-encrypted params..., signature, ssecurity: <plaintext ssecurity>, _nonce: <plaintext nonce>}`.

**Response decryption:** RC4-decrypt (same drop-1024 scheme, key =
`signed_nonce` recomputed from the request's own `_nonce`) the raw response
body, then `json.loads` it directly — no `&&&START&&&` prefix on these
(`decrypt_rc4`, lines 229-233; call site lines 154-156).

**API base URL:** `https://{region}.api.io.mi.com/app` for every region
except `cn`, which omits the subdomain prefix entirely:
`https://api.io.mi.com/app` (`get_api_url`, lines 159-161). Regions:
`cn de us ru tw sg in i2`.

## 3. Endpoints used, in call order

1. `POST /v2/homeroom/gethome` — `data={"fg": true, "fetch_share": true, "fetch_share_dev": true, "limit": 300, "app_ver": 7}`.
   Response: `result.homelist[]`, each `{id, ...}` → collect as
   `{home_id: id, home_owner: <own userId>}`.
2. `POST /v2/user/get_device_cnt` — `data={"fetch_own": true, "fetch_share": true}`.
   Response: `result.share.share_family[]`, each `{home_id, home_owner, ...}`
   → append to the same home list (covers homes shared *to* this account).
3. For each collected home: `POST /v2/home/home_device_list` —
   `data={"home_owner": <id>, "home_id": <id>, "limit": 200, "get_split_device": true, "support_smart_home": true}`.
   Response: `result.device_info[]`, each device object includes (subset
   that matters here): `did`, `name`, `mac`, `model`, `token`, `localip`.
4. For each device whose `did` **contains the substring `"blt"`** (BLE
   devices — this is a substring match on the did, e.g. `blt.3.xxxxx`, not
   an exact prefix check — `token_extractor.py:880`):
   `POST /v2/device/blt_get_beaconkey` — `data={"did": "<did>", "pdid": 1}`.
   Response: `result.beaconkey` — **this is the 16-byte auth key** used as
   `secretKey` in the BLE/RFCOMM handshake (`docs/PROTOCOL.md` §3), hex
   string. `miband auth-key` reads exactly this field.

Repeat steps 1-4 once per server region if none was specified (all 8
regions checked in turn until the band is found).

## 4. QR-code login (alternative to §1, not driven by `miband auth-key` yet)

`GET /longPolling/loginUrl` gets a QR image URL + a long-polling URL; the
user scans the QR with the Mi Home app; the long-polling GET blocks until
scanned/confirmed and returns the same `ssecurity`/`userId`/`location`
shape as the password path; then `GET <location>` for the `serviceToken`
cookie, same as §1.3 (`QrCodeXiaomiCloudConnector`, lines 605-754). No
password, no captcha, no email 2FA — trades those for "must have the phone
handy and the Mi Home app installed."

## Caveats for the Swift port

- `ssecurity` from the account-level login (§1) is different from and
  unrelated to any per-device session key from the BLE handshake
  (`docs/PROTOCOL.md` §3) — don't conflate the two "auth" flows.
- The vendored tool's own stdout prints each device's beaconkey as it runs
  (upstream behavior, `token_extractor.py:883`) — `miband auth-key`
  inherits that subprocess's stdout so you'll see it on screen during the
  interactive run; it is not otherwise logged or persisted anywhere except
  `.env`, and the tool's own full JSON dump (which contains *every* device
  and *every* token on the account, not just the band's) is deleted
  immediately after `miband auth-key` extracts the one field it needs.
- The `blt` substring check is exactly that — a substring check, not an
  exact match or prefix check. Copy that logic precisely; a stricter check
  in the Swift port could silently miss a valid device.
