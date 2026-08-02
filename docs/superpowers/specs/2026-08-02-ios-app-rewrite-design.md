# Manumit iOS app — full UI/UX rewrite design

Status: approved, pending implementation plan.

## Goal

Turn `ios/Manumit` from a single debug screen (auth-key field, connect
button, raw log) into a real app: onboarding, automatic connect, a
dashboard, health sync to Apple Health, and a "System" section for
managing what shows up on the band (hide built-in apps/widgets, delete
QuickApps).

## Non-goals

- No firmware modification. Built-in native apps are compiled into
  `vela_ap.bin`; no delete/uninstall command exists for them anywhere in
  the protocol (docs/PROTOCOL.md §8). "Hiding" them from the band's
  launcher via `DISPLAY_ITEMS_SET`/`WIDGET_SCREENS_SET` is the only
  supported mechanism, and it's what this design implements.
- No raw/generic command console. System actions are specific, mapped UI
  (hide/show toggle, quickapp delete) — not a free-form type/subtype/payload
  terminal.
- No background BLE. Sync only runs while the app is foregrounded and
  connected; no background modes, no silent push-triggered sync.
- No sleep-stage or daily-details-v5 sync in this pass — those parsers have
  known gaps (docs/PROTOCOL.md §6.3: no version-5 branch for daily-details,
  Band 10's layout there is still unconfirmed). Only daily-summary fields
  (steps, calories, heart rate) sync to HealthKit for now.
- No swift-protobuf/SPM dependency. New protobuf messages are hand-encoded
  in `ProtoWire.swift`, same pattern already used for Auth.

## Architecture

- `BandSession` stays the BLE/auth engine (already does M4 encrypted
  round-trip + M5 TODAY file-id fetch). Promoted from a view-local
  `@StateObject` to an app-wide `@EnvironmentObject` so every tab can read
  connection state and trigger sends.
- `OnboardingView` (new) — shown when `KeychainStore.load(account:
  "auth-key")` is nil. Auth-key entry (reuses existing `SecureField` UI from
  `ContentView`), then a HealthKit authorization request (steps, active +
  resting energy, heart rate), then hands off to the main app.
- `MainTabView` (new) — three tabs:
  - **Dashboard** — connection state, battery/device metadata (existing M4
    data), last-sync summary (date, records written), error banners.
  - **System** — app/widget visibility toggles, installed-QuickApp list
    with delete.
  - **Settings** — auth-key re-entry, "forget device" (clears the saved
    peripheral UUID from Keychain), fixture export (`ShareLink`, already
    exists), raw session log (moved here from the home screen — CLAUDE.md's
    instrumentation rule keeps fixture logging mandatory, it just isn't the
    primary UI anymore).
- `LocalStore.swift` (new) — SwiftData. One model, `DailySummaryRecord`
  (date, steps, calories, restingHR, maxHR, avgHR), upserted by date. This
  is the "stores data locally" half of the project's stated end goal
  (CLAUDE.md), and the source HealthKit writes are read from — so re-runs
  don't double-write.
- `HealthKitStore.swift` (new) — thin wrapper: `requestAuthorization()`,
  `write(_ record: DailySummaryRecord)`. No read-back from HealthKit; this
  app is a one-way writer.
- `DailySummaryParser.swift` (new) — decodes the version-5 daily-summary
  body (docs/PROTOCOL.md §6.3: 4-byte validity bitmap + 32 slots) into a
  `DailySummaryRecord`. Unrecognized/unsupported fields are dropped, not
  guessed at.
- `ProtoWire.swift` (extended) — adds hand-rolled encode/decode for the
  messages this milestone needs beyond Auth:
  - `Health.ActivitySyncRequestPast` (M5 only sends `ActivitySyncRequestToday`;
    PAST is needed to backfill more than today)
  - `System.DisplayItemsGet` / `DisplayItemsSet` (type=2, subtype=29/30)
  - `System.WidgetScreensGet` / `WidgetScreensSet` (type=2, subtype=51/52)
  - `Rpk.RpkInfoList` / `RpkInfo` (type=20, subtype=0/1/2/3)
- `SystemCommandService.swift` (new) — wraps send/receive for the four
  System-tab actions (get/set display items, list/delete quickapps) on top
  of `BandSession`'s existing encrypted send/receive plumbing.

## Data flow

1. App launch → Keychain has no auth key → `OnboardingView`.
2. Onboarding: enter auth key → save to Keychain → request HealthKit
   authorization → proceed to `MainTabView`.
3. `MainTabView` appears → `BandSession` auto-connects using the saved
   peripheral UUID (existing logic in `ContentView.onAppear`, ported
   as-is) → on reaching `.authenticated`, Dashboard shows battery/device
   info (existing M4 GET) and kicks off a background `Task`:
   - fetch TODAY + PAST file-id lists (extends M5, which only does TODAY)
   - for each file id, fetch the body, run it through `DailySummaryParser`
   - upsert into `LocalStore`
   - write new/changed records to HealthKit via `HealthKitStore`
4. Dashboard reflects sync status (last-synced date, record count),
   replacing the raw log as the primary view of "did this work."
5. System tab, on appear: `DISPLAY_ITEMS_GET` → render a toggle list;
   toggling sends `DISPLAY_ITEMS_SET`. `RPK_LIST` → render installed
   QuickApps with a Delete button → `RPK_DELETE`.
6. Settings tab: auth-key re-entry, forget-device, fixture export, raw log
   — unchanged functionality, relocated from the home screen.

## Error handling

- BLE/handshake errors: `HandshakeState` gets clearer categories, surfaced
  as Dashboard banners instead of only appearing as log lines.
- HealthKit authorization denied: Dashboard shows a banner ("sync
  disabled — enable in Settings.app"). Band connection, Dashboard, and
  System tab all keep working without it — HealthKit is additive, not a
  gate.
- Known parser gaps (sleep-stages, daily-details v5): explicitly skipped
  with a logged "unsupported record type," never a crash, never a guessed
  layout.
- `RPK_DELETE` sends no response by design (matches Gadgetbridge's
  `XiaomiRpkService.deleteRpk()`) — treated as success, followed by an
  immediate `RPK_LIST` re-request to refresh the UI.

## Testing

Single hardware checkpoint at the end of implementation (no intermediate
stops): sideload and confirm, in one session —
- onboarding saves the auth key and auto-connect succeeds
- Dashboard shows battery/device info
- steps/calories/heart rate appear in the Health app after sync
- System tab hides an app from the band's launcher and deletes a QuickApp

Anything short of all four working is not done.
