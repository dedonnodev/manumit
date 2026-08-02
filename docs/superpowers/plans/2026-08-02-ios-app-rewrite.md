# Manumit iOS App Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `ios/Manumit` from a single debug screen into a real app: onboarding, auto-connect, a dashboard, health sync to Apple Health, and a System tab for hiding built-in apps/widgets and deleting QuickApps.

**Architecture:** `BandSession` stays the BLE/auth/protocol engine, promoted to an app-wide `@EnvironmentObject`. New pure-logic modules (parser, local store, HealthKit mapping, protobuf message builders) are unit-testable and covered by a new XCTest target; new SwiftUI views wire them together and are verified manually at the single hardware checkpoint at the end.

**Tech Stack:** Swift 5 / SwiftUI, CoreBluetooth, CommonCrypto/CryptoKit (existing), HealthKit (new), XCTest (new), hand-rolled protobuf wire format in `ProtoWire.swift` (existing pattern, extended — no swift-protobuf/SPM dependency).

**Spec:** `docs/superpowers/specs/2026-08-02-ios-app-rewrite-design.md`

## Global Constraints

- Deployment target stays iOS 16.0 (`IPHONEOS_DEPLOYMENT_TARGET = 16.0` in `project.pbxproj`) — no SwiftData (needs 17+), no `HKQuantityType(.identifier)` enum-subscript init (needs 18+ SDK sugar); use `HKObjectType.quantityType(forIdentifier:)`.
- No swift-protobuf / SPM dependency. All new protobuf messages are hand-encoded in `ProtoWire.swift`, matching the existing `ProtoWriter`/`ProtoReader`/`XiaomiProto` pattern exactly.
- No firmware modification, no raw/generic command console — System-tab actions are specific and mapped (hide/show toggle, quickapp delete), per the spec's non-goals.
- No background BLE — sync only runs while the app is foregrounded and connected.
- Every new source file gets the same AGPLv3 header already used throughout `ios/Manumit/Manumit/*.swift` (copy verbatim, shown once in Task 1, reused unmodified after).
- No Swift/Xcode toolchain is available where this plan is executed (Linux, no `swift`/`xcodebuild`). Every "run the tests" step in this plan means: commit, push, and check the new `test` job in GitHub Actions (`.github/workflows/manumit-ipa.yml`) — not an instant local run. Say so explicitly in each task rather than pretending otherwise.
- **Open risk, not silently routed around:** the HealthKit entitlement (`com.apple.developer.healthkit`) may not be grantable under a free/personal-team signing identity when AltStore/SideStore re-signs the unsigned IPA for sideloading. Task 7 wires the entitlement correctly on the assumption it *is* grantable; if the final hardware checkpoint shows HealthKit authorization silently failing/denied due to signing, that is a structural block per CLAUDE.md ("if blocked by something structural, say so and stop") — not something to work around with a fallback store.

---

## Task 1: XCTest target + CI test job

No test infrastructure exists today — one app target, CI only runs `xcodebuild archive`. This adds a standard "unit tests with host application" target (the same shape Xcode's own "Include Tests" checkbox produces), so every later task can carry a real, CI-checked test instead of an unverifiable claim.

**Files:**
- Modify: `ios/Manumit/Manumit.xcodeproj/project.pbxproj`
- Modify: `ios/Manumit/Manumit.xcodeproj/xcshareddata/xcschemes/Manumit.xcscheme`
- Modify: `.github/workflows/manumit-ipa.yml`
- Create: `ios/Manumit/ManumitTests/SmokeTests.swift`

**Interfaces:**
- Produces: an XCTest target named `ManumitTests` (product `ManumitTests.xctest`), building with `TEST_HOST`/`BUNDLE_LOADER` pointing at `Manumit.app`, `@testable import Manumit` available to every test file added in later tasks. Every later task appends its test file's `PBXFileReference`/`PBXBuildFile` using the same recipe shown here (new IDs, same shape).

- [ ] **Step 1: Add the standard AGPLv3 header to reuse for every new file**

This exact 16-line block (copied from `ios/Manumit/Manumit/KeychainStore.swift:1-16`) goes at the top of every new Swift file created in this plan, followed by a file-specific one-line comment where useful:

```swift
// Copyright (C) 2026 miband contributors
//
// This file is part of miband.
//
// miband is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// miband is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
```

- [ ] **Step 2: Create the smoke test file**

`ios/Manumit/ManumitTests/SmokeTests.swift`:

```swift
// Copyright (C) 2026 miband contributors
//
// This file is part of miband.
//
// miband is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// miband is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// Proves the ManumitTests target actually builds, links against Manumit.app
// (TEST_HOST), and runs on CI -- before any real logic depends on it.

import XCTest
@testable import Manumit

final class SmokeTests: XCTestCase {
    func testArithmeticSanity() {
        XCTAssertEqual(2 + 2, 4)
    }
}
```

- [ ] **Step 3: Add the new PBXFileReference entries**

In `ios/Manumit/Manumit.xcodeproj/project.pbxproj`, inside the existing `/* Begin PBXFileReference section */ ... /* End PBXFileReference section */` block, add these lines right before the `/* End PBXFileReference section */` marker:

```
		CC0000000000000000000010 /* ManumitTests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = ManumitTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
		CC0000000000000000000011 /* XCTest.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = XCTest.framework; path = Platforms/iPhoneOS.platform/Developer/Library/Frameworks/XCTest.framework; sourceTree = DEVELOPER_DIR; };
		CC0000000000000000000099 /* SmokeTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SmokeTests.swift; sourceTree = "<group>"; };
```

- [ ] **Step 4: Add the new PBXBuildFile entries**

Inside `/* Begin PBXBuildFile section */ ... /* End PBXBuildFile section */`, before the `/* End */` marker:

```
		CC0000000000000000000012 /* XCTest.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = CC0000000000000000000011 /* XCTest.framework */; };
		CC0000000000000000000199 /* SmokeTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = CC0000000000000000000099 /* SmokeTests.swift */; };
```

- [ ] **Step 5: Add the PBXContainerItemProxy + PBXTargetDependency sections**

These two `isa` types don't exist in the file yet. Insert a brand-new block right after the `/* End PBXBuildFile section */` line (before `/* Begin PBXFileReference section */`):

```
/* Begin PBXContainerItemProxy section */
		CC0000000000000000000021 /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = BB0000000000000000000001 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = BB0000000000000000000030;
			remoteInfo = Manumit;
		};
/* End PBXContainerItemProxy section */

```

And a second new block right after `/* End PBXSourcesBuildPhase section */` (before `/* Begin XCBuildConfiguration section */`):

```
/* Begin PBXTargetDependency section */
		CC0000000000000000000022 /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = BB0000000000000000000030 /* Manumit */;
			targetProxy = CC0000000000000000000021 /* PBXContainerItemProxy */;
		};
/* End PBXTargetDependency section */

```

- [ ] **Step 6: Add the ManumitTests group**

Inside `/* Begin PBXGroup section */`, add a new group and reference it from the top-level group and add the test product to `Products`:

```
		CC0000000000000000000050 /* ManumitTests */ = {
			isa = PBXGroup;
			children = (
				CC0000000000000000000099 /* SmokeTests.swift */,
			);
			path = ManumitTests;
			sourceTree = "<group>";
		};
```

Then modify the existing top-level group (`BB0000000000000000000002`) to add the new group as a child, and the existing `Products` group (`BB0000000000000000000003`) to add the test product:

```
		BB0000000000000000000002 = {
			isa = PBXGroup;
			children = (
				BB0000000000000000000004 /* Manumit */,
				CC0000000000000000000050 /* ManumitTests */,
				BB0000000000000000000005 /* Frameworks */,
				BB0000000000000000000003 /* Products */,
			);
			sourceTree = "<group>";
		};
```

```
		BB0000000000000000000003 /* Products */ = {
			isa = PBXGroup;
			children = (
				BB0000000000000000000010 /* Manumit.app */,
				CC0000000000000000000010 /* ManumitTests.xctest */,
			);
			name = Products;
			sourceTree = "<group>";
		};
```

Also add `XCTest.framework` as a child of the existing `Frameworks` group (`BB0000000000000000000005`):

```
		BB0000000000000000000005 /* Frameworks */ = {
			isa = PBXGroup;
			children = (
				BB0000000000000000000013 /* CoreBluetooth.framework */,
				CC0000000000000000000011 /* XCTest.framework */,
			);
			name = Frameworks;
			sourceTree = "<group>";
		};
```

- [ ] **Step 7: Add the PBXNativeTarget**

Inside `/* Begin PBXNativeTarget section */`, add (after the existing `Manumit` target, before `/* End PBXNativeTarget section */`):

```
		CC0000000000000000000020 /* ManumitTests */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = CC0000000000000000000042 /* Build configuration list for PBXNativeTarget "ManumitTests" */;
			buildPhases = (
				CC0000000000000000000030 /* Sources */,
				CC0000000000000000000031 /* Frameworks */,
				CC0000000000000000000032 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
				CC0000000000000000000022 /* PBXTargetDependency */,
			);
			name = ManumitTests;
			productName = ManumitTests;
			productReference = CC0000000000000000000010 /* ManumitTests.xctest */;
			productType = "com.apple.product-type.bundle.unit-test";
		};
```

- [ ] **Step 8: Register the target with PBXProject**

Modify `BB0000000000000000000001 /* Project object */`: add `CC0000000000000000000020` to both `TargetAttributes` and `targets`:

```
			attributes = {
				LastSwiftUpdateCheck = 1500;
				LastUpgradeCheck = 1500;
				TargetAttributes = {
					BB0000000000000000000030 = {
						CreatedOnToolsVersion = 15.0;
					};
					CC0000000000000000000020 = {
						CreatedOnToolsVersion = 15.0;
						TestTargetID = BB0000000000000000000030;
					};
				};
			};
```

```
			targets = (
				BB0000000000000000000030 /* Manumit */,
				CC0000000000000000000020 /* ManumitTests */,
			);
```

- [ ] **Step 9: Add the build phases**

Inside `/* Begin PBXFrameworksBuildPhase section */`:

```
		CC0000000000000000000031 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				CC0000000000000000000012 /* XCTest.framework in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
```

Inside `/* Begin PBXResourcesBuildPhase section */`:

```
		CC0000000000000000000032 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
```

Inside `/* Begin PBXSourcesBuildPhase section */`:

```
		CC0000000000000000000030 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				CC0000000000000000000199 /* SmokeTests.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
```

- [ ] **Step 10: Add the build configurations**

Inside `/* Begin XCBuildConfiguration section */`, add both (Debug mirrors the app target's Debug settings; note `TEST_HOST`/`BUNDLE_LOADER` — the standard "unit tests with host app" wiring):

```
		CC0000000000000000000040 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				BUNDLE_LOADER = "$(TEST_HOST)";
				CODE_SIGN_IDENTITY = "";
				CODE_SIGNING_ALLOWED = NO;
				CODE_SIGNING_REQUIRED = NO;
				GENERATE_INFOPLIST_FILE = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 16.0;
				PRODUCT_BUNDLE_IDENTIFIER = "com.manumit.miband.tests";
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = iphoneos;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Manumit.app/Manumit";
			};
			name = Debug;
		};
		CC0000000000000000000041 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				BUNDLE_LOADER = "$(TEST_HOST)";
				CODE_SIGN_IDENTITY = "";
				CODE_SIGNING_ALLOWED = NO;
				CODE_SIGNING_REQUIRED = NO;
				GENERATE_INFOPLIST_FILE = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 16.0;
				PRODUCT_BUNDLE_IDENTIFIER = "com.manumit.miband.tests";
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = iphoneos;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Manumit.app/Manumit";
			};
			name = Release;
		};
```

- [ ] **Step 11: Add the configuration list**

Inside `/* Begin XCConfigurationList section */`:

```
		CC0000000000000000000042 /* Build configuration list for PBXNativeTarget "ManumitTests" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				CC0000000000000000000040 /* Debug */,
				CC0000000000000000000041 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
```

- [ ] **Step 12: Wire the scheme**

In `ios/Manumit/Manumit.xcodeproj/xcshareddata/xcschemes/Manumit.xcscheme`, add a second `BuildActionEntry` right after the existing one (inside `<BuildActionEntries>`):

```xml
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "NO"
            buildForProfiling = "NO"
            buildForArchiving = "NO"
            buildForAnalyzing = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "CC0000000000000000000020"
               BuildableName = "ManumitTests.xctest"
               BlueprintName = "ManumitTests"
               ReferencedContainer = "container:Manumit.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
```

Replace the empty `<Testables>\n      </Testables>` in `<TestAction>` with:

```xml
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "CC0000000000000000000020"
               BuildableName = "ManumitTests.xctest"
               BlueprintName = "ManumitTests"
               ReferencedContainer = "container:Manumit.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
```

- [ ] **Step 13: Add the CI test job**

In `.github/workflows/manumit-ipa.yml`, add a second job alongside the existing `build` job (same file, same triggers):

```yaml
  test:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Run unit tests (logic only -- no BLE/HealthKit, runs on simulator)
        run: |
          xcodebuild test \
            -project ios/Manumit/Manumit.xcodeproj \
            -scheme Manumit \
            -destination "platform=iOS Simulator,name=iPhone 15" \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGN_IDENTITY=""
```

- [ ] **Step 14: Commit**

```bash
git add ios/Manumit/Manumit.xcodeproj ios/Manumit/ManumitTests .github/workflows/manumit-ipa.yml
git commit -m "$(cat <<'EOF'
ios/Manumit: add XCTest target + CI test job

No Swift toolchain in this environment to run tests locally -- this
wires up the standard "unit tests with host app" target shape so
xcodebuild test runs for real on the macOS CI runner instead of relying
on unverifiable claims. Smoke test only; real logic tests land with the
tasks that introduce that logic.
EOF
)"
```

- [ ] **Step 15: Push and confirm the new CI job goes green**

This is the "run the test" step for this task, per the Global Constraints note — push the branch and check the Actions tab for the `test` job (not just `build`).

---

## Task 2: Activity file-id encode + PAST fetch

M5 only requests TODAY's file-id list. Extending to PAST needs (a) sending the bare PAST request and (b) being able to turn a received `DecodedActivityFileId` back into 7 raw bytes, which Task 3's per-file `FETCH_REQUEST`/`ACK` calls need too.

**Files:**
- Modify: `ios/Manumit/Manumit/ProtoWire.swift`
- Modify: `ios/Manumit/Manumit/BandSession.swift`
- Test: `ios/Manumit/ManumitTests/ActivityFileIdEncodeTests.swift`

**Interfaces:**
- Consumes: `XiaomiProto.DecodedActivityFileId` (existing, `ProtoWire.swift:150-155`), `XiaomiProto.commandTypeSubtypeOnly(type:subtype:)` (existing).
- Produces: `XiaomiProto.DecodedActivityFileId.encode() -> Data` (7 raw bytes), `BandSession.sendActivityFetchPastRequest()` (private, called from the TODAY response handler).

- [ ] **Step 1: Write the failing test**

`ios/Manumit/ManumitTests/ActivityFileIdEncodeTests.swift` (header from Task 1 Step 1 omitted below for brevity — include it):

```swift
import XCTest
@testable import Manumit

final class ActivityFileIdEncodeTests: XCTestCase {
    func testEncodeIsInverseOfDecode() {
        // Same synthetic bytes XiaomiProto.selfTest() already uses for decode.
        let raw = Data([0x64, 0x00, 0x00, 0x00, 0x04, 0x06, 0x00]) // ts=100, tz=4, version=6, flags=0x00
        let decoded = XiaomiProto.decodeActivityFileIds(fromHealth: {
            var w = ProtoWriter(); w.putBytes(2, raw); return w.data
        }())!
        XCTAssertEqual(decoded[0].encode(), raw)
    }

    func testPastRequestIsBareTypeSubtype() {
        // Command{type=8, subtype=2}, no health field at all
        // (XiaomiHealthService.java:816-824, fetchRecordedDataPast).
        let built = XiaomiProto.commandTypeSubtypeOnly(type: 8, subtype: 2)
        XCTAssertEqual(built, Data([0x08, 0x08, 0x10, 0x02]))
    }
}
```

- [ ] **Step 2: Push, confirm it fails**

`encode()` doesn't exist yet — expect a compile error in CI (`value of type 'XiaomiProto.DecodedActivityFileId' has no member 'encode'`).

- [ ] **Step 3: Add `encode()` to `ProtoWire.swift`**

In `ios/Manumit/Manumit/ProtoWire.swift`, extend the existing `DecodedActivityFileId` struct (currently `ProtoWire.swift:150-155`):

```swift
    /// One `XiaomiActivityFileId` (§6.1): 7 bytes, little-endian.
    struct DecodedActivityFileId {
        var timestamp: Date
        var timezoneBlocks: Int8 // 15-min blocks, signed (west of UTC is negative)
        var version: UInt8
        var flags: UInt8 // bit7=type bits1-6=subtype bits0-1=detailType -- raw, not decomposed (M6+)

        /// Inverse of `decodeActivityFileIds` -- the 7 raw bytes as received,
        /// needed to re-send this file id in a `CMD_ACTIVITY_FETCH_REQUEST` or
        /// `CMD_ACTIVITY_FETCH_ACK` (`XiaomiActivityFileId.java:83-90`).
        func encode() -> Data {
            var d = Data()
            let ts = UInt32(timestamp.timeIntervalSince1970)
            d.append(UInt8(ts & 0xFF))
            d.append(UInt8((ts >> 8) & 0xFF))
            d.append(UInt8((ts >> 16) & 0xFF))
            d.append(UInt8((ts >> 24) & 0xFF))
            d.append(UInt8(bitPattern: timezoneBlocks))
            d.append(version)
            d.append(flags)
            return d
        }
    }
```

- [ ] **Step 4: Wire PAST into `BandSession.swift`**

In `ios/Manumit/Manumit/BandSession.swift`, modify `logActivityFileIds` (currently just logs) and add the PAST sender. Replace the M5 section header comment and `sendActivityFetchTodayRequest`/`logActivityFileIds` (`BandSession.swift:370-401`) with:

```swift
    // MARK: - §6.2 activity file-id fetch (M5 TODAY, M6 extends to PAST)

    // Health{activitySyncRequestToday=ActivitySyncRequestToday{unknown1=0}}
    // (XiaomiHealthService.java:802-814, fetchRecordedDataToday).
    private func sendActivityFetchTodayRequest() {
        appendLog("requesting today's activity file ids")
        sendEncryptedData(rawChannel: 1, body: XiaomiProto.commandWithHealth(type: 8, subtype: 1, healthField: XiaomiProto.healthActivitySyncRequestToday()))
    }

    // Bare Command{type=8, subtype=2}, no health field
    // (XiaomiHealthService.java:816-824, fetchRecordedDataPast).
    private func sendActivityFetchPastRequest() {
        appendLog("requesting past activity file ids")
        sendEncryptedData(rawChannel: 1, body: XiaomiProto.commandTypeSubtypeOnly(type: 8, subtype: 2))
    }

    private static let activityFileIdFormatter = ISO8601DateFormatter()

    // subtype: 1=TODAY response (chain into PAST next, matching Gadgetbridge's
    // fetchRecordedDataPast() call from handleActivityFetchResponse when
    // subtype==CMD_ACTIVITY_FETCH_TODAY, XiaomiHealthService.java:878-880),
    // 2=PAST response (no further chaining -- Task 3 starts per-file fetch here).
    private func logActivityFileIds(_ fileIds: [XiaomiProto.DecodedActivityFileId], subtype: UInt64) {
        appendLog("got \(fileIds.count) activity file id(s)")
        for f in fileIds {
            appendLog("  file: \(Self.activityFileIdFormatter.string(from: f.timestamp)) tz=\(f.timezoneBlocks) version=\(f.version) flags=0x\(String(format: "%02X", f.flags))")
        }
        if let start = fixtureStart {
            let entries: [[String: Any]] = fileIds.map {
                [
                    "timestamp": Self.activityFileIdFormatter.string(from: $0.timestamp),
                    "timezone_blocks": Int($0.timezoneBlocks),
                    "version": Int($0.version),
                    "flags": Int($0.flags),
                ]
            }
            writeFixtureLine([
                "t": ProcessInfo.processInfo.systemUptime - start,
                "direction": "rx",
                "activity_file_ids": entries,
            ])
        }
        if subtype == 1 {
            sendActivityFetchPastRequest()
        }
        // Task 3 adds: enqueue fileIds for per-file body fetch here.
    }
```

Update the call site in `handleEncryptedCommand` (`BandSession.swift:358-363`) to pass `subtype`:

```swift
        case (8, 1), (8, 2):
            guard let healthBytes = command.healthBytes,
                  let fileIds = XiaomiProto.decodeActivityFileIds(fromHealth: healthBytes) else {
                appendLog("could not parse activity file id response (health bytes=\(command.healthBytes?.count ?? 0))")
                return
            }
            logActivityFileIds(fileIds, subtype: command.subtype)
```

- [ ] **Step 5: Add the test file to the Xcode project**

`PBXFileReference` (in the existing section):
```
		CC0000000000000000000100 /* ActivityFileIdEncodeTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ActivityFileIdEncodeTests.swift; sourceTree = "<group>"; };
```
`PBXBuildFile`:
```
		CC0000000000000000000200 /* ActivityFileIdEncodeTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = CC0000000000000000000100 /* ActivityFileIdEncodeTests.swift */; };
```
Add to `ManumitTests` group's `children` (`CC0000000000000000000050`) and to the test target's `Sources` phase `files` (`CC0000000000000000000030`).

- [ ] **Step 6: Push, confirm CI `test` job is green**

- [ ] **Step 7: Commit**

```bash
git add ios/Manumit/Manumit.xcodeproj ios/Manumit/Manumit/ProtoWire.swift ios/Manumit/Manumit/BandSession.swift ios/Manumit/ManumitTests/ActivityFileIdEncodeTests.swift
git commit -m "$(cat <<'EOF'
ios/Manumit: activity file-id encode + PAST fetch (M6)

Extends M5's TODAY-only file-id fetch to also request PAST, and adds
the encode() needed to re-send a received file id in the per-file
fetch/ack Task 3 adds next.
EOF
)"
```

---

## Task 3: CRC32 + activity file-body fetch/reassembly

The chunked-transfer half of §6.2 (steps 3-5): request each file id, reassemble the `[uint16 total][uint16 num][payload]`-chunked response over `CHANNEL_DATA` (raw_channel=2, always plaintext — confirmed in `docs/PROTOCOL.md` §5.0), verify the CRC32 trailer, and hand the reassembled bytes off (Task 4 plugs in the parser).

**Files:**
- Create: `ios/Manumit/Manumit/CRC32.swift`
- Modify: `ios/Manumit/Manumit/BandSession.swift`
- Test: `ios/Manumit/ManumitTests/ActivityFileFetchTests.swift`

**Interfaces:**
- Consumes: `XiaomiProto.DecodedActivityFileId.encode()` (Task 2), `XiaomiProto.commandWithHealth(type:subtype:healthField:)` (existing).
- Produces: `CRC32.checksum(_ data: Data) -> UInt32`. `BandSession` gains a fetch queue and `handleActivityFileBody(_ data: Data)` (private) that Task 4 will call `DailySummaryParser.parse` from.

- [ ] **Step 1: Write the failing tests**

`ios/Manumit/ManumitTests/ActivityFileFetchTests.swift`:

```swift
import XCTest
@testable import Manumit

final class ActivityFileFetchTests: XCTestCase {
    func testCRC32MatchesKnownVector() {
        // Standard CRC-32/ISO-HDLC check value for ASCII "123456789" (used to
        // validate every CRC-32 implementation against every other one).
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF43926)
    }

    func testCRC32OfEmptyIsZero() {
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    func testChunkReassemblyAndCrcCheck() {
        // Build a fake file: 7-byte fileId + 1 padding byte + 2 body bytes,
        // then a real CRC32 trailer over all of it, split into two chunks.
        let fileIdBytes = Data([0x64, 0x00, 0x00, 0x00, 0x04, 0x06, 0x00])
        let body = fileIdBytes + Data([0x00]) + Data([0xAA, 0xBB])
        let crc = CRC32.checksum(body)
        var full = body
        full.append(UInt8(crc & 0xFF))
        full.append(UInt8((crc >> 8) & 0xFF))
        full.append(UInt8((crc >> 16) & 0xFF))
        full.append(UInt8((crc >> 24) & 0xFF))

        let fetcher = ActivityFileFetchBuffer()
        // chunk 1/2
        var chunk1 = Data([2, 0, 1, 0]) // total=2, num=1 (LE uint16 each)
        chunk1.append(full.prefix(6))
        XCTAssertNil(fetcher.addChunk(chunk1))
        // chunk 2/2
        var chunk2 = Data([2, 0, 2, 0])
        chunk2.append(full.suffix(from: 6))
        let result = fetcher.addChunk(chunk2)
        XCTAssertEqual(result, full)
    }

    func testBadCrcIsRejected() {
        let fileIdBytes = Data([0x64, 0x00, 0x00, 0x00, 0x04, 0x06, 0x00])
        var full = fileIdBytes + Data([0x00, 0xAA, 0xBB])
        full.append(contentsOf: [0, 0, 0, 0]) // wrong CRC
        let fetcher = ActivityFileFetchBuffer()
        var chunk = Data([1, 0, 1, 0])
        chunk.append(full)
        XCTAssertNil(fetcher.addChunk(chunk))
    }
}
```

- [ ] **Step 2: Push, confirm it fails**

`CRC32` and `ActivityFileFetchBuffer` don't exist yet -- compile failure.

- [ ] **Step 3: Create `CRC32.swift`**

```swift
// Copyright (C) 2026 miband contributors
//
// This file is part of miband.
//
// miband is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// miband is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// Standard CRC-32 (IEEE 802.3 / "CRC-32/ISO-HDLC", poly 0xEDB88320
// reflected) -- same algorithm as Java's java.util.zip.CRC32, which
// XiaomiActivityFileFetcher.java:121 uses to validate the activity file
// trailer (§6.2 step 5).

import Foundation

enum CRC32 {
    private static let table: [UInt32] = (0...255).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
```

- [ ] **Step 4: Add a standalone, testable reassembly buffer**

Rather than testing chunk reassembly only through the full `BandSession` (which needs a live `CBPeripheral`), extract the pure logic into its own small class that `BandSession` owns and delegates to. Add to `ios/Manumit/Manumit/BandSession.swift`, near the top (after the `HandshakeState` enum, before `final class BandSession`):

```swift
/// §6.2 step 4-5: reassembles `[uint16 total][uint16 num][payload]`-chunked
/// activity file transfers (`XiaomiActivityFileFetcher.java:91-145`) and
/// verifies the CRC32 trailer. Pure/synchronous, no BLE -- separated out so
/// it's unit-testable without a live peripheral.
final class ActivityFileFetchBuffer {
    private var buffer = Data()

    /// Feed one chunk. Returns the full verified file bytes (fileId + padding
    /// + body, CRC trailer included) once the last chunk of a transfer
    /// arrives and its CRC32 checks out; nil while still accumulating, and
    /// nil (logged, buffer dropped) if the CRC doesn't match or the chunk
    /// header is malformed -- never guessed at.
    func addChunk(_ chunk: Data) -> Data? {
        guard chunk.count >= 4 else { return nil }
        let base = chunk.startIndex
        let total = UInt16(chunk[base]) | UInt16(chunk[base + 1]) << 8
        let num = UInt16(chunk[base + 2]) | UInt16(chunk[base + 3]) << 8
        if num == 1 { buffer = Data() }
        buffer.append(chunk.suffix(from: base + 4))
        guard num == total else { return nil }

        let data = buffer
        buffer = Data()
        guard data.count >= 7 + 1 + 4 else { return nil } // fileId + padding + at least an empty body + CRC
        let bodyEnd = data.index(data.endIndex, offsetBy: -4)
        let expectedCrc = UInt32(data[bodyEnd]) | UInt32(data[bodyEnd + 1]) << 8
            | UInt32(data[bodyEnd + 2]) << 16 | UInt32(data[bodyEnd + 3]) << 24
        let body = data[data.startIndex..<bodyEnd]
        guard CRC32.checksum(Data(body)) == expectedCrc else { return nil }
        return data
    }
}
```

- [ ] **Step 5: Wire it into `BandSession`**

Add a stored property and dispatch. In the property list near `rxBuffer`/`sendSeq` (`BandSession.swift:87-88`):

```swift
    private var rxBuffer = Data()
    private var sendSeq: UInt8 = 0
    private let activityFetchBuffer = ActivityFileFetchBuffer()
    private var pendingActivityFileIds: [XiaomiProto.DecodedActivityFileId] = []
```

In `handle(packet:)` (`BandSession.swift:281-304`), the current code drops everything but `rawChannel == 1`. Replace:

```swift
            guard rawChannel == 1 else { return } // only the Protobuf command channel, for this milestone
            switch opCode {
            case 1: // plaintext -- Auth only (§2.3)
                handleAuthCommand(body: body)
            case 2: // encrypted -- everything else, once authenticated (§4.2)
                guard let derivedKeys = derivedKeys else { return }
                let decrypted = AuthCrypto.ctrCrypt(key: derivedKeys.decryptionKey, data: body)
                logDecrypted(hex: hexString(decrypted))
                handleEncryptedCommand(body: decrypted)
            default:
                break
            }
```

with:

```swift
            switch rawChannel {
            case 1: // Protobuf command channel
                switch opCode {
                case 1: // plaintext -- Auth only (§2.3)
                    handleAuthCommand(body: body)
                case 2: // encrypted -- everything else, once authenticated (§4.2)
                    guard let derivedKeys = derivedKeys else { return }
                    let decrypted = AuthCrypto.ctrCrypt(key: derivedKeys.decryptionKey, data: body)
                    logDecrypted(hex: hexString(decrypted))
                    handleEncryptedCommand(body: decrypted)
                default:
                    break
                }
            case 2: // CHANNEL_DATA -- activity file chunks, always plaintext (§5.0, §6.2 step 4)
                if let fileBytes = activityFetchBuffer.addChunk(body) {
                    handleActivityFileBody(fileBytes)
                }
            default:
                break
            }
```

Add the fetch-queue driver and per-file request/ack, replacing the `// Task 3 adds:` placeholder comment left in Task 2's `logActivityFileIds`:

```swift
        if subtype == 1 {
            sendActivityFetchPastRequest()
        }
        pendingActivityFileIds.append(contentsOf: fileIds)
        if pendingActivityFileIds.count == fileIds.count {
            // wasn't already mid-fetch -- kick off the queue
            requestNextActivityFile()
        }
    }

    // MARK: - §6.2 step 3-6: per-file body fetch (M6)

    private func requestNextActivityFile() {
        guard !pendingActivityFileIds.isEmpty else {
            appendLog("activity fetch queue empty")
            return
        }
        let fileId = pendingActivityFileIds[0]
        appendLog("requesting file body: \(Self.activityFileIdFormatter.string(from: fileId.timestamp))")
        var health = ProtoWriter()
        health.putBytes(2, fileId.encode()) // Health.activityRequestFileIds, field 2
        sendEncryptedData(rawChannel: 1, body: XiaomiProto.commandWithHealth(type: 8, subtype: 3, healthField: health.data))
    }

    private func ackActivityFile(_ fileId: XiaomiProto.DecodedActivityFileId) {
        var health = ProtoWriter()
        health.putBytes(3, fileId.encode()) // Health.activitySyncAckFileIds, field 3
        sendEncryptedData(rawChannel: 1, body: XiaomiProto.commandWithHealth(type: 8, subtype: 5, healthField: health.data))
    }

    private func handleActivityFileBody(_ data: Data) {
        guard !pendingActivityFileIds.isEmpty else {
            appendLog("got activity file body with no pending request, dropping")
            return
        }
        let fileId = pendingActivityFileIds.removeFirst()
        appendLog("got file body (\(data.count) bytes) for \(Self.activityFileIdFormatter.string(from: fileId.timestamp))")
        // Task 4 plugs in: DailySummaryParser.parse(fileId:, bytes: data) -> LocalStore/HealthKit
        ackActivityFile(fileId)
        requestNextActivityFile()
    }
```

- [ ] **Step 6: Add the test file to the Xcode project**

Same recipe as Task 2 Step 5, using `CC0000000000000000000101`/`CC0000000000000000000201` for `ActivityFileFetchTests.swift`.

- [ ] **Step 7: Push, confirm CI `test` job is green**

- [ ] **Step 8: Commit**

```bash
git add ios/Manumit/Manumit/CRC32.swift ios/Manumit/Manumit/BandSession.swift ios/Manumit/Manumit.xcodeproj ios/Manumit/ManumitTests/ActivityFileFetchTests.swift
git commit -m "$(cat <<'EOF'
ios/Manumit: activity file-body fetch + CRC32 reassembly (M6)

Completes §6.2's per-file fetch/ack loop: request each file id in
sequence, reassemble the CHANNEL_DATA chunked response, verify the
CRC32 trailer, ack, move to the next. Reassembly logic lives in its
own ActivityFileFetchBuffer so it's unit-testable without a live BLE
peripheral.
EOF
)"
```

---

## Task 4: DailySummaryParser

Decodes the version-5 daily-summary body (§6.3) into a typed record. Only version 5 ("Mi Band 10 and later") is implemented — v3/v4 are older bands, explicitly out of scope.

**Files:**
- Create: `ios/Manumit/Manumit/DailySummaryParser.swift`
- Modify: `ios/Manumit/Manumit/BandSession.swift`
- Test: `ios/Manumit/ManumitTests/DailySummaryParserTests.swift`

**Interfaces:**
- Consumes: `XiaomiProto.DecodedActivityFileId` (existing).
- Produces: `struct DailySummaryRecord: Codable, Equatable` (date, steps, activeCalories, totalCalories, restingHeartRate, minHeartRate/minHeartRateTimestamp, maxHeartRate/maxHeartRateTimestamp, avgHeartRate) and `DailySummaryParser.parse(fileId:bytes:) -> DailySummaryRecord?`. Task 5 (`LocalStore`) and Task 6 (`HealthKitStore`) both consume `DailySummaryRecord`.

- [ ] **Step 1: Write the failing tests**

Build a synthetic version-5 body matching the documented layout (4-byte header + 32 slots, `DailySummaryParser.java:39-73`) and check the handful of fields this app cares about, plus one negative case for a header validity bit clearing a slot.

`ios/Manumit/ManumitTests/DailySummaryParserTests.swift`:

```swift
import XCTest
@testable import Manumit

final class DailySummaryParserTests: XCTestCase {
    // Builds a full 32-slot v5 body with every validity bit set, and known
    // values in the slots this app reads (0 steps, 1 activeCalories, 3
    // restingHR, 4/5 maxHR+ts, 6/7 minHR+ts, 8 avgHR, 13 totalCalories).
    // Every other slot is zero-filled bytes of the right width per
    // DailySummaryParser.java's SLOTS table.
    private func makeBody(headerBits: [Bool] = Array(repeating: true, count: 32)) -> Data {
        var header: [UInt8] = [0, 0, 0, 0]
        for (i, bit) in headerBits.enumerated() where bit {
            header[i / 8] |= UInt8(1 << (7 - (i % 8)))
        }
        var body = Data()
        func u8(_ v: UInt8) { body.append(v) }
        func u16(_ v: UInt16) { body.append(UInt8(v & 0xFF)); body.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) {
            body.append(UInt8(v & 0xFF)); body.append(UInt8((v >> 8) & 0xFF))
            body.append(UInt8((v >> 16) & 0xFF)); body.append(UInt8((v >> 24) & 0xFF))
        }
        u32(8000)      // 0 steps
        u16(300)       // 1 activeCalories
        u8(0)          // 2 reserved
        u8(58)         // 3 restingHR
        u8(142)        // 4 maxHR
        u32(1700000100) // 5 maxHRTs
        u8(50)         // 6 minHR
        u32(1700000000) // 7 minHRTs
        u8(72)         // 8 avgHR
        u8(0); u8(0); u8(0) // 9,10,11 stress avg/max/min
        body.append(contentsOf: [0, 0, 0]) // 12 standing bitmap (3 bytes)
        u16(1800)      // 13 totalCalories
        u16(0)         // 14 recovery hours
        u8(0)          // 15 reserved
        u8(0); u32(0); u8(0); u32(0); u8(0) // 16,17,18,19,20 SpO2
        u16(0); u16(0) // 21,22 training load day/week
        u8(0); u8(0); u8(0); u8(0) // 23,24,25,26
        u16(0)         // 27 vitality current
        u8(0); u8(0)   // 28,29 reserved
        u16(0); u16(0) // 30,31 reserved

        var full = Data([0x64, 0x00, 0x00, 0x00, 0x08, 0x05, 0x00]) // fileId: ts=100, tz=8, version=5, flags=0
        full.append(0) // padding
        full.append(contentsOf: header)
        full.append(body)
        return full
    }

    private let fileId = XiaomiProto.DecodedActivityFileId(
        timestamp: Date(timeIntervalSince1970: 100), timezoneBlocks: 8, version: 5, flags: 0
    )

    func testDecodesKnownFields() {
        let record = DailySummaryParser.parse(fileId: fileId, bytes: makeBody())
        XCTAssertEqual(record?.steps, 8000)
        XCTAssertEqual(record?.activeCalories, 300)
        XCTAssertEqual(record?.totalCalories, 1800)
        XCTAssertEqual(record?.restingHeartRate, 58)
        XCTAssertEqual(record?.maxHeartRate, 142)
        XCTAssertEqual(record?.maxHeartRateTimestamp, Date(timeIntervalSince1970: 1700000100))
        XCTAssertEqual(record?.minHeartRate, 50)
        XCTAssertEqual(record?.avgHeartRate, 72)
    }

    func testInvalidBitDropsField() {
        var bits = Array(repeating: true, count: 32)
        bits[3] = false // restingHR slot marked invalid
        let record = DailySummaryParser.parse(fileId: fileId, bytes: makeBody(headerBits: bits))
        XCTAssertNil(record?.restingHeartRate)
        XCTAssertEqual(record?.steps, 8000) // other slots unaffected
    }

    func testUnsupportedVersionReturnsNil() {
        let v4 = XiaomiProto.DecodedActivityFileId(timestamp: Date(), timezoneBlocks: 0, version: 4, flags: 0)
        XCTAssertNil(DailySummaryParser.parse(fileId: v4, bytes: makeBody()))
    }

    func testTruncatedBodyReturnsNilNotCrash() {
        XCTAssertNil(DailySummaryParser.parse(fileId: fileId, bytes: Data([0, 1, 2])))
    }
}
```

- [ ] **Step 2: Push, confirm it fails**

`DailySummaryParser` / `DailySummaryRecord` don't exist -- compile failure.

- [ ] **Step 3: Create `DailySummaryParser.swift`**

```swift
// Copyright (C) 2026 miband contributors
//
// This file is part of miband.
//
// miband is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// miband is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// Daily-summary body decoder (docs/PROTOCOL.md §6.3), version 5 only
// ("Mi Band 10 and later" -- DailySummaryParser.java:140). v3/v4 (21-slot,
// 3-byte header) are older bands, out of scope. Slot layout/order matches
// DailySummaryParser.java's SLOTS table verbatim, including the reserved
// slots -- they must still be consumed to keep the cursor aligned even
// though this app doesn't store their values.

import Foundation

struct DailySummaryRecord: Codable, Equatable {
    var date: Date // local day this record covers, per fileId.timezoneBlocks
    var steps: Int
    var activeCalories: Int
    var totalCalories: Int
    var restingHeartRate: Int?
    var minHeartRate: Int?
    var minHeartRateTimestamp: Date?
    var maxHeartRate: Int?
    var maxHeartRateTimestamp: Date?
    var avgHeartRate: Int?
}

enum DailySummaryParser {
    private static func validBit(_ header: [UInt8], _ i: Int) -> Bool {
        (header[i / 8] & (1 << (7 - (i % 8)))) != 0
    }

    static func parse(fileId: XiaomiProto.DecodedActivityFileId, bytes: Data) -> DailySummaryRecord? {
        guard fileId.version == 5 else { return nil }
        let raw = [UInt8](bytes)
        guard raw.count >= 7 + 1 + 4 else { return nil } // fileId + padding + header, at minimum

        var offset = 7 // skip the 7-byte fileId prefix (§6.2 step 5)
        offset += 1    // padding byte, expected 0 -- not fatal if not, matches Java's warn-and-continue
        let header = Array(raw[offset..<offset + 4])
        offset += 4

        func hasMore(_ n: Int) -> Bool { offset + n <= raw.count }
        func u8() -> UInt8 { defer { offset += 1 }; return raw[offset] }
        func u16() -> UInt16 { defer { offset += 2 }; return UInt16(raw[offset]) | UInt16(raw[offset + 1]) << 8 }
        func u32() -> UInt32 {
            defer { offset += 4 }
            return UInt32(raw[offset]) | UInt32(raw[offset + 1]) << 8
                | UInt32(raw[offset + 2]) << 16 | UInt32(raw[offset + 3]) << 24
        }

        var steps = 0, activeCalories = 0, totalCalories = 0
        var restingHR: Int?
        var minHR: Int?, minHRTs: Date?
        var maxHR: Int?, maxHRTs: Date?
        var avgHR: Int?

        for slot in 0..<32 {
            let valid = validBit(header, slot)
            switch slot {
            case 0: guard hasMore(4) else { return nil }; let v = Int(u32()); if valid { steps = v }
            case 1: guard hasMore(2) else { return nil }; let v = Int(u16()); if valid { activeCalories = v }
            case 2: guard hasMore(1) else { return nil }; _ = u8() // reserved
            case 3: guard hasMore(1) else { return nil }; let v = Int(u8()); if valid { restingHR = v }
            case 4: guard hasMore(1) else { return nil }; let v = Int(u8()); if valid { maxHR = v }
            case 5: guard hasMore(4) else { return nil }; let v = u32(); if valid { maxHRTs = Date(timeIntervalSince1970: TimeInterval(v)) }
            case 6: guard hasMore(1) else { return nil }; let v = Int(u8()); if valid { minHR = v }
            case 7: guard hasMore(4) else { return nil }; let v = u32(); if valid { minHRTs = Date(timeIntervalSince1970: TimeInterval(v)) }
            case 8: guard hasMore(1) else { return nil }; let v = Int(u8()); if valid { avgHR = v }
            case 9, 10, 11: guard hasMore(1) else { return nil }; _ = u8() // stress avg/max/min -- not synced (v1 scope)
            case 12: guard hasMore(3) else { return nil }; offset += 3 // standing bitmap -- not synced
            case 13: guard hasMore(2) else { return nil }; let v = Int(u16()); if valid { totalCalories = v }
            case 14: guard hasMore(2) else { return nil }; _ = u16() // recovery hours
            case 15: guard hasMore(1) else { return nil }; _ = u8() // reserved
            case 16: guard hasMore(1) else { return nil }; _ = u8() // SpO2 max
            case 17: guard hasMore(4) else { return nil }; _ = u32() // SpO2 max ts
            case 18: guard hasMore(1) else { return nil }; _ = u8() // SpO2 min
            case 19: guard hasMore(4) else { return nil }; _ = u32() // SpO2 min ts
            case 20: guard hasMore(1) else { return nil }; _ = u8() // SpO2 avg
            case 21, 22: guard hasMore(2) else { return nil }; _ = u16() // training load day/week
            case 23, 24, 25, 26: guard hasMore(1) else { return nil }; _ = u8() // training load level, vitality light/mod/high
            case 27: guard hasMore(2) else { return nil }; _ = u16() // vitality current
            case 28, 29: guard hasMore(1) else { return nil }; _ = u8() // reserved
            case 30, 31: guard hasMore(2) else { return nil }; _ = u16() // reserved
            default: break
            }
        }

        // Local calendar day this file covers: shift by the reported
        // timezone offset (15-min blocks) before truncating to a day
        // boundary, so the dedup key in LocalStore (Task 5) lines up with
        // wall-clock date, not raw UTC date.
        let shifted = fileId.timestamp.addingTimeInterval(TimeInterval(fileId.timezoneBlocks) * 15 * 60)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let dayStart = utcCalendar.startOfDay(for: shifted)

        return DailySummaryRecord(
            date: dayStart,
            steps: steps, activeCalories: activeCalories, totalCalories: totalCalories,
            restingHeartRate: restingHR,
            minHeartRate: minHR, minHeartRateTimestamp: minHRTs,
            maxHeartRate: maxHR, maxHeartRateTimestamp: maxHRTs,
            avgHeartRate: avgHR
        )
    }
}
```

- [ ] **Step 4: Wire the parser into `BandSession`**

Replace the `// Task 4 plugs in:` placeholder in `handleActivityFileBody` (added in Task 3) with:

```swift
        if let record = DailySummaryParser.parse(fileId: fileId, bytes: data) {
            appendLog("parsed daily summary: steps=\(record.steps) calories=\(record.totalCalories)")
            // Task 5/6 plug in here: LocalStore.upsert(record) -> HealthKitStore.save
        } else {
            appendLog("unsupported or unparseable activity file (version=\(fileId.version)), skipping")
        }
```

- [ ] **Step 5: Add the test file to the Xcode project**

Same recipe, `CC0000000000000000000102`/`CC0000000000000000000202` for `DailySummaryParserTests.swift`, plus the new source file in the app target: fileRef `BB0000000000000000000100`, buildFile `BB0000000000000000000200`, added to `Manumit` group (`BB0000000000000000000004`) children and the app's `Sources` phase (`BB0000000000000000000040`) files.

- [ ] **Step 6: Push, confirm CI `test` job is green**

- [ ] **Step 7: Commit**

```bash
git add ios/Manumit/Manumit/DailySummaryParser.swift ios/Manumit/Manumit/BandSession.swift ios/Manumit/Manumit.xcodeproj ios/Manumit/ManumitTests/DailySummaryParserTests.swift
git commit -m "$(cat <<'EOF'
ios/Manumit: daily-summary parser (v5, M6)

Decodes the version-5 daily-summary body (docs/PROTOCOL.md §6.3) into
DailySummaryRecord -- steps, calories, and heart-rate min/max/avg/resting.
v3/v4 (older bands) explicitly unsupported, returns nil rather than
guessing at a layout that isn't Band 10's.
EOF
)"
```

---

## Task 5: LocalStore

Codable-backed local persistence — not SwiftData (deployment target is iOS 16, SwiftData needs 17+). One JSON file, a dictionary keyed by date string, upserted.

**Files:**
- Create: `ios/Manumit/Manumit/LocalStore.swift`
- Test: `ios/Manumit/ManumitTests/LocalStoreTests.swift`

**Interfaces:**
- Consumes: `DailySummaryRecord` (Task 4).
- Produces: `LocalStore.upsert(_ record: DailySummaryRecord) -> Bool` (returns `true` if new-or-changed, i.e. HealthKit needs writing), `LocalStore.all() -> [DailySummaryRecord]`. `LocalStore` takes a file URL in its initializer so tests use a temp file instead of the real Application Support path.

- [ ] **Step 1: Write the failing tests**

`ios/Manumit/ManumitTests/LocalStoreTests.swift`:

```swift
import XCTest
@testable import Manumit

final class LocalStoreTests: XCTestCase {
    private func tempStore() -> LocalStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        return LocalStore(fileURL: url)
    }

    private func record(day: Int, steps: Int) -> DailySummaryRecord {
        DailySummaryRecord(
            date: Date(timeIntervalSince1970: TimeInterval(day * 86400)),
            steps: steps, activeCalories: 0, totalCalories: 0,
            restingHeartRate: nil, minHeartRate: nil, minHeartRateTimestamp: nil,
            maxHeartRate: nil, maxHeartRateTimestamp: nil, avgHeartRate: nil
        )
    }

    func testUpsertNewRecordReturnsTrue() {
        let store = tempStore()
        XCTAssertTrue(store.upsert(record(day: 1, steps: 100)))
        XCTAssertEqual(store.all().count, 1)
    }

    func testUpsertUnchangedRecordReturnsFalse() {
        let store = tempStore()
        _ = store.upsert(record(day: 1, steps: 100))
        XCTAssertFalse(store.upsert(record(day: 1, steps: 100)))
        XCTAssertEqual(store.all().count, 1)
    }

    func testUpsertChangedRecordReturnsTrueAndReplaces() {
        let store = tempStore()
        _ = store.upsert(record(day: 1, steps: 100))
        XCTAssertTrue(store.upsert(record(day: 1, steps: 200)))
        XCTAssertEqual(store.all().first?.steps, 200)
        XCTAssertEqual(store.all().count, 1)
    }

    func testPersistsAcrossInstances() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        _ = LocalStore(fileURL: url).upsert(record(day: 1, steps: 100))
        let reopened = LocalStore(fileURL: url)
        XCTAssertEqual(reopened.all().count, 1)
        XCTAssertEqual(reopened.all().first?.steps, 100)
    }
}
```

- [ ] **Step 2: Push, confirm it fails**

`LocalStore` doesn't exist -- compile failure.

- [ ] **Step 3: Create `LocalStore.swift`**

```swift
// Copyright (C) 2026 miband contributors
//
// This file is part of miband.
//
// miband is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// miband is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// Local storage half of CLAUDE.md's end goal ("stores data locally, writes
// it to Apple Health"). Not SwiftData -- deployment target is iOS 16,
// SwiftData needs 17+. A Codable dictionary in one JSON file is enough for
// "one record per day, upsert by day."

import Foundation

final class LocalStore {
    private let fileURL: URL
    private var records: [String: DailySummaryRecord]

    static let shared = LocalStore(fileURL: {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("daily-summaries.json")
    }())

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: DailySummaryRecord].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func key(for record: DailySummaryRecord) -> String {
        Self.keyFormatter.string(from: record.date)
    }

    /// Returns true if this record is new or different from what was
    /// stored -- the caller (BandSession's sync) uses this to decide
    /// whether a HealthKit write is needed, so re-syncing an unchanged day
    /// doesn't create duplicate samples.
    @discardableResult
    func upsert(_ record: DailySummaryRecord) -> Bool {
        let k = key(for: record)
        guard records[k] != record else { return false }
        records[k] = record
        persist()
        return true
    }

    func all() -> [DailySummaryRecord] {
        Array(records.values)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Add both files to the Xcode project**

`LocalStore.swift`: fileRef `BB0000000000000000000101`, buildFile `BB0000000000000000000201`, added to `Manumit` group + app `Sources` phase.
`LocalStoreTests.swift`: fileRef `CC0000000000000000000103`, buildFile `CC0000000000000000000203`, added to `ManumitTests` group + test `Sources` phase.

- [ ] **Step 5: Push, confirm CI `test` job is green**

- [ ] **Step 6: Commit**

```bash
git add ios/Manumit/Manumit/LocalStore.swift ios/Manumit/Manumit.xcodeproj ios/Manumit/ManumitTests/LocalStoreTests.swift
git commit -m "$(cat <<'EOF'
ios/Manumit: local daily-summary store (Codable, no SwiftData)

One JSON file, upserted by day, dedupes so re-syncing an unchanged day
doesn't produce duplicate HealthKit writes downstream. SwiftData would
need a deployment-target bump to iOS 17; this needs neither that nor a
new framework.
EOF
)"
```

---

## Task 6: HealthKitStore

Entitlement + Info.plist wiring, authorization request, and a pure record-to-sample mapping function that's unit-testable without HealthKit authorization. The actual `save()` call is not unit tested — it needs a real, authorized `HKHealthStore`, verified only at the final hardware checkpoint.

**Files:**
- Create: `ios/Manumit/Manumit/Manumit.entitlements`
- Create: `ios/Manumit/Manumit/HealthKitStore.swift`
- Modify: `ios/Manumit/Manumit.xcodeproj/project.pbxproj`
- Test: `ios/Manumit/ManumitTests/HealthKitMappingTests.swift`

**Interfaces:**
- Consumes: `DailySummaryRecord` (Task 4).
- Produces: `HealthKitStore.requestAuthorization(store:completion:)`, `HealthKitStore.makeSamples(for:) -> [HKQuantitySample]` (pure, tested), `HealthKitStore.save(_:store:completion:)` (not unit tested).

- [ ] **Step 1: Write the failing tests**

`ios/Manumit/ManumitTests/HealthKitMappingTests.swift`:

```swift
import XCTest
import HealthKit
@testable import Manumit

final class HealthKitMappingTests: XCTestCase {
    private func record() -> DailySummaryRecord {
        DailySummaryRecord(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            steps: 8000, activeCalories: 300, totalCalories: 1800,
            restingHeartRate: 58,
            minHeartRate: 50, minHeartRateTimestamp: Date(timeIntervalSince1970: 1_700_000_000),
            maxHeartRate: 142, maxHeartRateTimestamp: Date(timeIntervalSince1970: 1_700_000_100),
            avgHeartRate: 72
        )
    }

    func testMapsStepsAndCalories() {
        let samples = HealthKitStore.makeSamples(for: record())
        let steps = samples.first { $0.quantityType == HKObjectType.quantityType(forIdentifier: .stepCount)! }
        XCTAssertEqual(steps?.quantity.doubleValue(for: .count()), 8000)

        let active = samples.first { $0.quantityType == HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)! }
        XCTAssertEqual(active?.quantity.doubleValue(for: .kilocalorie()), 300)

        // basal = total - active
        let basal = samples.first { $0.quantityType == HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)! }
        XCTAssertEqual(basal?.quantity.doubleValue(for: .kilocalorie()), 1500)
    }

    func testMapsHeartRateSamplesAtTheirOwnTimestamps() {
        let samples = HealthKitStore.makeSamples(for: record())
        let hrType = HKObjectType.quantityType(forIdentifier: .heartRate)!
        let hrSamples = samples.filter { $0.quantityType == hrType }
        XCTAssertEqual(hrSamples.count, 3) // min, max, avg

        let max = hrSamples.first { $0.quantity.doubleValue(for: .count().unitDivided(by: .minute())) == 142 }
        XCTAssertEqual(max?.startDate, Date(timeIntervalSince1970: 1_700_000_100))

        let resting = samples.first { $0.quantityType == HKObjectType.quantityType(forIdentifier: .restingHeartRate)! }
        XCTAssertEqual(resting?.quantity.doubleValue(for: .count().unitDivided(by: .minute())), 58)
    }

    func testZeroBasalOmitted() {
        var r = record()
        r.totalCalories = r.activeCalories // basal would be 0
        let samples = HealthKitStore.makeSamples(for: r)
        XCTAssertNil(samples.first { $0.quantityType == HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)! })
    }
}
```

- [ ] **Step 2: Push, confirm it fails**

`HealthKitStore` doesn't exist -- compile failure.

- [ ] **Step 3: Create the entitlements file**

`ios/Manumit/Manumit/Manumit.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.healthkit</key>
	<true/>
</dict>
</plist>
```

- [ ] **Step 4: Create `HealthKitStore.swift`**

```swift
// Copyright (C) 2026 miband contributors
//
// This file is part of miband.
//
// miband is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// miband is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// One-way writer: DailySummaryRecord -> HealthKit. Uses the classic
// HKObjectType.quantityType(forIdentifier:) API, not the iOS 18
// HKQuantityType(.stepCount) sugar -- deployment target is iOS 16.

import Foundation
import HealthKit

enum HealthKitStore {
    static let stepType = HKObjectType.quantityType(forIdentifier: .stepCount)!
    static let activeEnergyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
    static let basalEnergyType = HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)!
    static let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)!
    static let restingHeartRateType = HKObjectType.quantityType(forIdentifier: .restingHeartRate)!

    static func requestAuthorization(store: HKHealthStore, completion: @escaping (Bool) -> Void) {
        let types: Set<HKSampleType> = [stepType, activeEnergyType, basalEnergyType, heartRateType, restingHeartRateType]
        store.requestAuthorization(toShare: types, read: []) { success, _ in
            DispatchQueue.main.async { completion(success) }
        }
    }

    /// Pure mapping, no HealthKit I/O -- unit-testable without authorization.
    /// `totalCalories - activeCalories` is written as basal/resting energy
    /// (Gadgetbridge's daily-summary has no separate "resting calories"
    /// field; `calories` (slot 13) is the total, `activeCalories` (slot 1)
    /// the active portion -- the difference is the resting/basal share).
    static func makeSamples(for record: DailySummaryRecord) -> [HKQuantitySample] {
        var samples: [HKQuantitySample] = []
        let dayStart = record.date
        let dayEnd = record.date.addingTimeInterval(24 * 3600)

        if record.steps > 0 {
            samples.append(HKQuantitySample(
                type: stepType,
                quantity: HKQuantity(unit: .count(), doubleValue: Double(record.steps)),
                start: dayStart, end: dayEnd
            ))
        }
        if record.activeCalories > 0 {
            samples.append(HKQuantitySample(
                type: activeEnergyType,
                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: Double(record.activeCalories)),
                start: dayStart, end: dayEnd
            ))
        }
        let basal = record.totalCalories - record.activeCalories
        if basal > 0 {
            samples.append(HKQuantitySample(
                type: basalEnergyType,
                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: Double(basal)),
                start: dayStart, end: dayEnd
            ))
        }
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        if let resting = record.restingHeartRate {
            samples.append(HKQuantitySample(
                type: restingHeartRateType,
                quantity: HKQuantity(unit: bpmUnit, doubleValue: Double(resting)),
                start: dayStart, end: dayEnd
            ))
        }
        if let max = record.maxHeartRate, let ts = record.maxHeartRateTimestamp {
            samples.append(HKQuantitySample(type: heartRateType, quantity: HKQuantity(unit: bpmUnit, doubleValue: Double(max)), start: ts, end: ts))
        }
        if let min = record.minHeartRate, let ts = record.minHeartRateTimestamp {
            samples.append(HKQuantitySample(type: heartRateType, quantity: HKQuantity(unit: bpmUnit, doubleValue: Double(min)), start: ts, end: ts))
        }
        if let avg = record.avgHeartRate {
            let noon = dayStart.addingTimeInterval(12 * 3600) // no per-sample timestamp for the daily average
            samples.append(HKQuantitySample(type: heartRateType, quantity: HKQuantity(unit: bpmUnit, doubleValue: Double(avg)), start: noon, end: noon))
        }
        return samples
    }

    static func save(_ record: DailySummaryRecord, store: HKHealthStore, completion: @escaping (Bool) -> Void) {
        let samples = makeSamples(for: record)
        guard !samples.isEmpty else { completion(true); return }
        store.save(samples) { success, _ in
            DispatchQueue.main.async { completion(success) }
        }
    }
}
```

- [ ] **Step 5: Wire the entitlement, Info.plist keys, and framework into the pbxproj**

Add `HealthKit.framework` file reference (in `/* Begin PBXFileReference section */`):
```
		BB0000000000000000000109 /* HealthKit.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = HealthKit.framework; path = System/Library/Frameworks/HealthKit.framework; sourceTree = SDKROOT; };
		BB0000000000000000000110 /* Manumit.entitlements */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Manumit.entitlements; sourceTree = "<group>"; };
```
Build file (in `/* Begin PBXBuildFile section */`):
```
		BB0000000000000000000209 /* HealthKit.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = BB0000000000000000000109 /* HealthKit.framework */; };
```
Add to the app's `Frameworks` phase `files` (`BB0000000000000000000041`) and to the `Frameworks` group's children (`BB0000000000000000000005`, alongside `CoreBluetooth.framework`). Add `Manumit.entitlements` to the `Manumit` group's children (`BB0000000000000000000004`).

Modify both app-target `XCBuildConfiguration` blocks (`BB0000000000000000000060` Debug and `BB0000000000000000000061` Release) to add:
```
					CODE_SIGN_ENTITLEMENTS = Manumit/Manumit.entitlements;
					INFOPLIST_KEY_NSHealthShareUsageDescription = "Not used -- Manumit only writes to Health, never reads.";
					INFOPLIST_KEY_NSHealthUpdateUsageDescription = "Used to write steps, calories, and heart rate from your Xiaomi Smart Band 10.";
```

- [ ] **Step 6: Add both new Swift files to the Xcode project**

`HealthKitStore.swift`: fileRef `BB0000000000000000000102`, buildFile `BB0000000000000000000202`, `Manumit` group + app `Sources` phase.
`HealthKitMappingTests.swift`: fileRef `CC0000000000000000000104`, buildFile `CC0000000000000000000204`, `ManumitTests` group + test `Sources` phase.

- [ ] **Step 7: Push, confirm CI `test` job is green**

- [ ] **Step 8: Commit**

```bash
git add ios/Manumit/Manumit/Manumit.entitlements ios/Manumit/Manumit/HealthKitStore.swift ios/Manumit/Manumit.xcodeproj ios/Manumit/ManumitTests/HealthKitMappingTests.swift
git commit -m "$(cat <<'EOF'
ios/Manumit: HealthKit write path (entitlement + mapping)

Record-to-sample mapping is pure and unit tested; requestAuthorization/
save need a real authorized HKHealthStore and are only verified at the
final hardware checkpoint. Open risk (documented in the plan): the
HealthKit entitlement may not be grantable under free/personal-team
sideload signing -- if authorization silently fails there, that's a
structural block, not something to route around.
EOF
)"
```

---

## Task 7: System protocol messages + SystemCommandService

Adds the hand-rolled protobuf messages for hiding/showing display items and listing/deleting QuickApps (`type=2` System, `type=20` Rpk), plus a service wrapper on top of `BandSession`'s send/receive plumbing.

**Files:**
- Modify: `ios/Manumit/Manumit/ProtoWire.swift`
- Create: `ios/Manumit/Manumit/SystemCommandService.swift`
- Modify: `ios/Manumit/Manumit/BandSession.swift`
- Test: `ios/Manumit/ManumitTests/SystemRpkProtoTests.swift`

**Interfaces:**
- Consumes: `ProtoWriter`/`ProtoReader`/`XiaomiProto.decodeCommand` (existing), `BandSession` (extended with a generic `sendCommand`/callback hook).
- Produces: `XiaomiProto.DecodedDisplayItem`, `XiaomiProto.commandSetDisplayItems(_:)`, `XiaomiProto.decodeDisplayItems(fromSystem:)`, `XiaomiProto.DecodedRpkInfo`, `XiaomiProto.commandDeleteRpk(id:sha:)`, `XiaomiProto.decodeRpkList(fromRpk:)`. `SystemCommandService` exposes `getDisplayItems()`, `setDisplayItems(_:)`, `getRpkList()`, `deleteRpk(id:sha:)`, publishing results via `@Published` properties Task 10 (SystemView) reads.

- [ ] **Step 1: Write the failing tests**

Byte-level encode/decode round trips, no BLE needed.

`ios/Manumit/ManumitTests/SystemRpkProtoTests.swift`:

```swift
import XCTest
@testable import Manumit

final class SystemRpkProtoTests: XCTestCase {
    func testDisplayItemsGetIsBareTypeSubtype() {
        // CMD_DISPLAY_ITEMS_GET=29 (XiaomiSystemService.java:90)
        XCTAssertEqual(XiaomiProto.commandTypeSubtypeOnly(type: 2, subtype: 29), Data([0x08, 0x02, 0x10, 0x1D]))
    }

    func testDisplayItemsSetRoundTrip() {
        let items = [
            XiaomiProto.DecodedDisplayItem(code: "weather", name: "Weather", disabled: false, isSettings: 0, inMoreSection: false),
            XiaomiProto.DecodedDisplayItem(code: "compass", name: "Compass", disabled: true, isSettings: 0, inMoreSection: true),
        ]
        let built = XiaomiProto.commandSetDisplayItems(items)
        let decoded = XiaomiProto.decodeCommand(built)
        XCTAssertEqual(decoded.type, 2)
        XCTAssertEqual(decoded.subtype, 30) // CMD_DISPLAY_ITEMS_SET
        guard let systemBytes = decoded.systemBytes, let roundTripped = XiaomiProto.decodeDisplayItems(fromSystem: systemBytes) else {
            return XCTFail("should decode back")
        }
        XCTAssertEqual(roundTripped.count, 2)
        XCTAssertEqual(roundTripped[1].code, "compass")
        XCTAssertTrue(roundTripped[1].disabled)
        XCTAssertTrue(roundTripped[1].inMoreSection)
    }

    func testRpkListIsBareTypeSubtype() {
        XCTAssertEqual(XiaomiProto.commandRpkList(), Data([0x08, 0x14, 0x10, 0x00]))
    }

    func testRpkListDecodesResponse() {
        var info1 = ProtoWriter(); info1.putString(1, "com.xiaomi.smarthome.watch"); info1.putString(5, "Mi Home")
        var list = ProtoWriter(); list.putMessage(1, info1.data)
        var rpk = ProtoWriter(); rpk.putMessage(1, list.data)
        var cmd = ProtoWriter(); cmd.putVarint(1, 20); cmd.putVarint(2, 0); cmd.putMessage(22, rpk.data)

        let decoded = XiaomiProto.decodeCommand(cmd.data)
        guard let rpkBytes = decoded.rpkBytes, let apps = XiaomiProto.decodeRpkList(fromRpk: rpkBytes) else {
            return XCTFail("should decode rpk list")
        }
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].id, "com.xiaomi.smarthome.watch")
        XCTAssertEqual(apps[0].name, "Mi Home")
    }

    func testDeleteRpkEncodesIdAndSha() {
        let sha = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let built = XiaomiProto.commandDeleteRpk(id: "com.example.app", sha: sha)
        let decoded = XiaomiProto.decodeCommand(built)
        XCTAssertEqual(decoded.type, 20)
        XCTAssertEqual(decoded.subtype, 3) // CMD_RPK_DELETE
        XCTAssertNotNil(decoded.rpkBytes)
    }
}
```

- [ ] **Step 2: Push, confirm it fails**

None of `DecodedDisplayItem`/`commandSetDisplayItems`/`decodeDisplayItems`/`commandRpkList`/`decodeRpkList`/`commandDeleteRpk`/`rpkBytes` exist -- compile failure.

- [ ] **Step 3: Extend `ProtoWire.swift`**

Add `rpkBytes` to `DecodedCommand` and its decode (`ProtoWire.swift:130-137, 226-246`):

```swift
    struct DecodedCommand {
        var type: UInt64
        var subtype: UInt64
        var authBytes: Data?
        var systemBytes: Data?
        var healthBytes: Data?
        var rpkBytes: Data?
        var status: UInt64?
    }
```

```swift
    static func decodeCommand(_ data: Data) -> DecodedCommand {
        var r = ProtoReader(data)
        var type: UInt64 = 0, subtype: UInt64 = 0
        var authBytes: Data?
        var systemBytes: Data?
        var healthBytes: Data?
        var rpkBytes: Data?
        var status: UInt64?
        while r.hasMore {
            let (field, wireType) = r.readTag()
            switch (field, wireType) {
            case (1, 0): type = r.readVarint()
            case (2, 0): subtype = r.readVarint()
            case (3, 2): authBytes = r.readBytes()
            case (4, 2): systemBytes = r.readBytes()
            case (10, 2): healthBytes = r.readBytes()
            case (22, 2): rpkBytes = r.readBytes()
            case (100, 0): status = r.readVarint()
            default: r.skip(wireType: wireType)
            }
        }
        return DecodedCommand(type: type, subtype: subtype, authBytes: authBytes, systemBytes: systemBytes, healthBytes: healthBytes, rpkBytes: rpkBytes, status: status)
    }
```

Add new builders/parsers at the end of the `XiaomiProto` enum, before the closing brace (after `decodeWatchNonce`, before `selfTest()`):

```swift
    // -- §8 System.displayItems (type=2, field 10) --

    struct DecodedDisplayItem {
        var code: String
        var name: String
        var disabled: Bool
        var isSettings: UInt64
        var inMoreSection: Bool
    }

    /// GET is bare type/subtype (use `commandTypeSubtypeOnly(type: 2, subtype: 29)`).
    /// SET always re-sends the *full* item list with `disabled` toggled --
    /// never a partial diff (`XiaomiSystemService.java:601-622`).
    static func commandSetDisplayItems(_ items: [DecodedDisplayItem]) -> Data {
        var itemsWriter = ProtoWriter()
        for item in items {
            var iw = ProtoWriter()
            iw.putString(1, item.code)
            iw.putString(2, item.name)
            iw.putVarint(3, item.disabled ? 1 : 0)
            if item.isSettings != 0 { iw.putVarint(4, item.isSettings) }
            if item.inMoreSection { iw.putVarint(6, 1) }
            itemsWriter.putMessage(1, iw.data)
        }
        var systemWriter = ProtoWriter()
        systemWriter.putMessage(10, itemsWriter.data) // System.displayItems, field 10
        var w = ProtoWriter()
        w.putVarint(1, 2)
        w.putVarint(2, 30) // CMD_DISPLAY_ITEMS_SET (XiaomiSystemService.java:91)
        w.putMessage(4, systemWriter.data) // Command.system, field 4
        return w.data
    }

    static func decodeDisplayItems(fromSystem systemBytes: Data) -> [DecodedDisplayItem]? {
        var sr = ProtoReader(systemBytes)
        var itemsBytes: Data?
        while sr.hasMore {
            let (field, wireType) = sr.readTag()
            if field == 10, wireType == 2 { itemsBytes = sr.readBytes() } else { sr.skip(wireType: wireType) }
        }
        guard let itemsBytes = itemsBytes else { return nil }
        var ir = ProtoReader(itemsBytes)
        var result: [DecodedDisplayItem] = []
        while ir.hasMore {
            let (field, wireType) = ir.readTag()
            guard field == 1, wireType == 2 else { ir.skip(wireType: wireType); continue }
            var pr = ProtoReader(ir.readBytes())
            var code = "", name = "", disabled = false, isSettings: UInt64 = 0, inMore = false
            while pr.hasMore {
                let (f, wt) = pr.readTag()
                switch (f, wt) {
                case (1, 2): code = String(data: pr.readBytes(), encoding: .utf8) ?? ""
                case (2, 2): name = String(data: pr.readBytes(), encoding: .utf8) ?? ""
                case (3, 0): disabled = pr.readVarint() != 0
                case (4, 0): isSettings = pr.readVarint()
                case (6, 0): inMore = pr.readVarint() != 0
                default: pr.skip(wireType: wt)
                }
            }
            result.append(DecodedDisplayItem(code: code, name: name, disabled: disabled, isSettings: isSettings, inMoreSection: inMore))
        }
        return result
    }

    // -- §8 Rpk / QuickApps (type=20, Command.rpk = field 22) --

    struct DecodedRpkInfo {
        var id: String
        var name: String
        var sha: Data
    }

    static func commandRpkList() -> Data {
        commandTypeSubtypeOnly(type: 20, subtype: 0) // CMD_RPK_LIST (XiaomiRpkService.java:41)
    }

    /// No response expected -- the band just gets deleted; the phone
    /// re-requests the list immediately after (`XiaomiRpkService.java:104-124`).
    static func commandDeleteRpk(id: String, sha: Data) -> Data {
        var delWriter = ProtoWriter()
        delWriter.putString(1, id)
        delWriter.putBytes(2, sha)
        var rpkWriter = ProtoWriter()
        rpkWriter.putMessage(5, delWriter.data) // Rpk.rpkDel, field 5
        var w = ProtoWriter()
        w.putVarint(1, 20)
        w.putVarint(2, 3) // CMD_RPK_DELETE (XiaomiRpkService.java:42)
        w.putMessage(22, rpkWriter.data) // Command.rpk, field 22
        return w.data
    }

    static func decodeRpkList(fromRpk rpkBytes: Data) -> [DecodedRpkInfo]? {
        var rr = ProtoReader(rpkBytes)
        var listBytes: Data?
        while rr.hasMore {
            let (field, wireType) = rr.readTag()
            if field == 1, wireType == 2 { listBytes = rr.readBytes() } else { rr.skip(wireType: wireType) }
        }
        guard let listBytes = listBytes else { return nil }
        var lr = ProtoReader(listBytes)
        var result: [DecodedRpkInfo] = []
        while lr.hasMore {
            let (field, wireType) = lr.readTag()
            guard field == 1, wireType == 2 else { lr.skip(wireType: wireType); continue }
            var pr = ProtoReader(lr.readBytes())
            var id = "", name = "", sha = Data()
            while pr.hasMore {
                let (f, wt) = pr.readTag()
                switch (f, wt) {
                case (1, 2): id = String(data: pr.readBytes(), encoding: .utf8) ?? ""
                case (5, 2): name = String(data: pr.readBytes(), encoding: .utf8) ?? ""
                case (2, 2): sha = pr.readBytes()
                default: pr.skip(wireType: wt)
                }
            }
            result.append(DecodedRpkInfo(id: id, name: name, sha: sha))
        }
        return result
    }
```

- [ ] **Step 4: Give `BandSession` a generic send + a result callback**

`SystemCommandService` needs to send arbitrary encrypted command bodies and get told about `type=2`/`type=20` responses. Add a public send method and a delegate-style callback property. In `BandSession.swift`, add near the top of the class body (after the `@Published` properties):

```swift
    // Generic hook for services built on top of the encrypted channel
    // (SystemCommandService) -- separate from the M4/M5/M6 flow above,
    // which only cares about its own (type, subtype) pairs.
    var onEncryptedCommand: ((XiaomiProto.DecodedCommand) -> Void)?

    func sendEncryptedCommand(_ body: Data) {
        sendEncryptedData(rawChannel: 1, body: body)
    }
```

And call it from `handleEncryptedCommand` (`BandSession.swift:347-368`), at the top of the function body, before the existing `switch`:

```swift
    private func handleEncryptedCommand(body: Data) {
        let command = XiaomiProto.decodeCommand(body)
        onEncryptedCommand?(command)
        switch (command.type, command.subtype) {
```

- [ ] **Step 5: Create `SystemCommandService.swift`**

```swift
// Copyright (C) 2026 miband contributors
//
// This file is part of miband.
//
// miband is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// miband is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// System tab actions: hide/show built-in apps (System.displayItems) and
// list/delete QuickApps (Rpk). Specific, mapped commands -- not a raw/
// generic console (spec non-goal).

import Foundation
import Combine

final class SystemCommandService: ObservableObject {
    @Published private(set) var displayItems: [XiaomiProto.DecodedDisplayItem] = []
    @Published private(set) var installedApps: [XiaomiProto.DecodedRpkInfo] = []

    private let session: BandSession
    private var previousHandler: ((XiaomiProto.DecodedCommand) -> Void)?

    init(session: BandSession) {
        self.session = session
        self.previousHandler = session.onEncryptedCommand
        session.onEncryptedCommand = { [weak self] command in
            self?.previousHandler?(command)
            self?.handle(command)
        }
    }

    private func handle(_ command: XiaomiProto.DecodedCommand) {
        switch (command.type, command.subtype) {
        case (2, 29): // CMD_DISPLAY_ITEMS_GET response
            if let systemBytes = command.systemBytes, let items = XiaomiProto.decodeDisplayItems(fromSystem: systemBytes) {
                DispatchQueue.main.async { self.displayItems = items }
            }
        case (20, 0): // CMD_RPK_LIST response
            if let rpkBytes = command.rpkBytes, let apps = XiaomiProto.decodeRpkList(fromRpk: rpkBytes) {
                DispatchQueue.main.async { self.installedApps = apps }
            }
        default:
            break
        }
    }

    func getDisplayItems() {
        session.sendEncryptedCommand(XiaomiProto.commandTypeSubtypeOnly(type: 2, subtype: 29))
    }

    func setDisplayItems(_ items: [XiaomiProto.DecodedDisplayItem]) {
        session.sendEncryptedCommand(XiaomiProto.commandSetDisplayItems(items))
        displayItems = items // optimistic local update -- band sends no confirming response
    }

    func getRpkList() {
        session.sendEncryptedCommand(XiaomiProto.commandRpkList())
    }

    func deleteRpk(id: String, sha: Data) {
        session.sendEncryptedCommand(XiaomiProto.commandDeleteRpk(id: id, sha: sha))
        getRpkList() // band sends no delete response -- re-request immediately (XiaomiRpkService.java:104-124)
    }
}
```

- [ ] **Step 6: Add the new files to the Xcode project**

`SystemCommandService.swift`: fileRef `BB0000000000000000000103`, buildFile `BB0000000000000000000203`, `Manumit` group + app `Sources` phase.
`SystemRpkProtoTests.swift`: fileRef `CC0000000000000000000105`, buildFile `CC0000000000000000000205`, `ManumitTests` group + test `Sources` phase.

- [ ] **Step 7: Push, confirm CI `test` job is green**

- [ ] **Step 8: Commit**

```bash
git add ios/Manumit/Manumit/ProtoWire.swift ios/Manumit/Manumit/SystemCommandService.swift ios/Manumit/Manumit/BandSession.swift ios/Manumit/Manumit.xcodeproj ios/Manumit/ManumitTests/SystemRpkProtoTests.swift
git commit -m "$(cat <<'EOF'
ios/Manumit: System display-items + Rpk protocol messages (M6)

Hand-rolled protobuf for hiding/showing built-in apps
(System.displayItems, type=2) and listing/deleting QuickApps (Rpk,
type=20), plus SystemCommandService wrapping both on top of
BandSession's existing encrypted send/receive. This is the mechanism
tools like MB10-Toolbox use -- not firmware modification.
EOF
)"
```

---

## Task 8: KeychainStore.delete + OnboardingView + app routing

First UI task. Adds "forget this value" to `KeychainStore`, a first-run onboarding screen, and routes `ManumitApp` between Onboarding and the main app based on whether an auth key is saved.

**Files:**
- Modify: `ios/Manumit/Manumit/KeychainStore.swift`
- Create: `ios/Manumit/Manumit/OnboardingView.swift`
- Modify: `ios/Manumit/Manumit/ManumitApp.swift`
- Modify: `ios/Manumit/Manumit.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `KeychainStore.load(account:)`/`save(_:account:)` (existing), `HealthKitStore.requestAuthorization` (Task 6).
- Produces: `KeychainStore.delete(account:)`. `OnboardingView` calls a completion closure when done (auth key saved + HealthKit prompt dismissed, regardless of grant/deny), which `ManumitApp` uses to flip its routing state.

No new pure logic here (SwiftUI view + a one-line Keychain addition) — no unit test possible without a simulator; this is the manual-verification kind of task the Global Constraints note flags. Verified at the final hardware checkpoint (Task 12).

- [ ] **Step 1: Add `delete` to `KeychainStore.swift`**

```swift
    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
```

- [ ] **Step 2: Create `OnboardingView.swift`**

```swift
// Copyright (C) 2026 miband contributors
//
// This file is part of miband.
//
// miband is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// miband is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import SwiftUI
import HealthKit

private let keychainAccount = "auth-key"

struct OnboardingView: View {
    let onDone: () -> Void

    @State private var authKeyHex = ""
    @State private var step: Step = .authKey

    enum Step { case authKey, healthKit }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case .authKey:
                Text("Connect your Band 10").font(.largeTitle.bold())
                Text("Auth key (32 hex chars, from `uv run miband auth-key`)").font(.caption)
                SecureField("MIBAND_AUTH_KEY", text: $authKeyHex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Continue") {
                    KeychainStore.save(authKeyHex, account: keychainAccount)
                    step = .healthKit
                }
                .disabled(authKeyHex.count != 32)
            case .healthKit:
                Text("Sync to Apple Health").font(.largeTitle.bold())
                Text("Manumit writes steps, calories, and heart rate from your band to the Health app. It never reads anything back.")
                    .font(.body)
                Button("Allow") {
                    HealthKitStore.requestAuthorization(store: HKHealthStore()) { _ in onDone() }
                }
                Button("Not now") { onDone() }
            }
            Spacer()
        }
        .padding()
    }
}
```

- [ ] **Step 3: Route in `ManumitApp.swift`**

Replace the whole file:

```swift
// Copyright (C) 2026 miband contributors
//
// This file is part of miband.
//
// miband is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// miband is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

private let keychainAccount = "auth-key"

@main
struct ManumitApp: App {
    @State private var onboarded = KeychainStore.load(account: keychainAccount) != nil

    init() {
        #if DEBUG
        SppV2Codec.selfTest()
        XiaomiProto.selfTest()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            if onboarded {
                Text("Main app lands in Task 9") // Task 9 Step 4 replaces this with MainTabView()
            } else {
                OnboardingView { onboarded = true }
            }
        }
    }
}
```

`MainTabView` doesn't exist until Task 9 — this task must stay buildable on its own, so it uses a literal placeholder `Text` instead of forward-referencing a type that doesn't exist yet.

- [ ] **Step 4: Add `OnboardingView.swift` to the Xcode project**

fileRef `BB0000000000000000000104`, buildFile `BB0000000000000000000204`, `Manumit` group + app `Sources` phase.

- [ ] **Step 5: Push, confirm CI `build` and `test` jobs are both green**

(This task only touches SwiftUI/app wiring — no new test file. Confirm nothing broke, not that something new is verified.)

- [ ] **Step 6: Commit**

```bash
git add ios/Manumit/Manumit/KeychainStore.swift ios/Manumit/Manumit/OnboardingView.swift ios/Manumit/Manumit/ManumitApp.swift ios/Manumit/Manumit.xcodeproj
git commit -m "$(cat <<'EOF'
ios/Manumit: onboarding flow + Keychain delete

First-run screen: auth key entry, then a HealthKit permission prompt.
ManumitApp now routes to Onboarding when no auth key is saved yet, and
to the main app otherwise. KeychainStore.delete backs the Settings
tab's "forget device" action added in Task 11.
EOF
)"
```

---

## Task 9: MainTabView + DashboardView + sync wiring

Ties everything together: the tab shell, the dashboard (metadata + sync status), and the background sync task that runs `BandSession` → `DailySummaryParser` → `LocalStore` → `HealthKitStore` once authenticated.

**Files:**
- Create: `ios/Manumit/Manumit/MainTabView.swift`
- Create: `ios/Manumit/Manumit/DashboardView.swift`
- Modify: `ios/Manumit/Manumit/BandSession.swift`
- Modify: `ios/Manumit/Manumit/ManumitApp.swift`
- Modify: `ios/Manumit/Manumit.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `BandSession` (extended), `LocalStore.shared`, `HealthKitStore`, `SystemCommandService` (constructed here, passed down to Task 10's `SystemView`).
- Produces: `BandSession.onDailySummaryParsed: ((DailySummaryRecord) -> Void)?` hook; `MainTabView`, `DashboardView`.

No new pure logic — UI wiring, manually verified at the final hardware checkpoint.

- [ ] **Step 1: Give `BandSession` a hook for parsed records**

In `BandSession.swift`, replace the placeholder comment left in Task 4 Step 4:

```swift
        if let record = DailySummaryParser.parse(fileId: fileId, bytes: data) {
            appendLog("parsed daily summary: steps=\(record.steps) calories=\(record.totalCalories)")
            onDailySummaryParsed?(record)
        } else {
            appendLog("unsupported or unparseable activity file (version=\(fileId.version)), skipping")
        }
```

Add the property near `onEncryptedCommand` (Task 7 Step 4):

```swift
    var onDailySummaryParsed: ((DailySummaryRecord) -> Void)?
```

- [ ] **Step 2: Create `MainTabView.swift`**

```swift
// Copyright (C) 2026 miband contributors
//
// This file is part of miband.
//
// miband is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// miband is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

struct MainTabView: View {
    @StateObject private var session = BandSession()
    @StateObject private var systemCommands: SystemCommandService
    private let healthStore = HKHealthStore()

    init() {
        let session = BandSession()
        _session = StateObject(wrappedValue: session)
        _systemCommands = StateObject(wrappedValue: SystemCommandService(session: session))
    }

    var body: some View {
        TabView {
            DashboardView(healthStore: healthStore)
                .environmentObject(session)
                .tabItem { Label("Dashboard", systemImage: "gauge") }
            // Task 10 adds a System tab here; Task 11 adds a Settings tab.
        }
    }
}
```

(`import HealthKit` needed for `HKHealthStore` — add it. `systemCommands` is unused by the view body until Task 10 wires in `SystemView` — Swift won't warn/fail on an unused `@StateObject` property, so this still compiles standalone.)

Note on sequencing: `MainTabView` only has one tab until Task 10 and Task 11 each add theirs — this keeps every task's code buildable on its own instead of Task 9 depending on files Tasks 10-11 haven't created yet.

- [ ] **Step 3: Create `DashboardView.swift`**

```swift
// Copyright (C) 2026 miband contributors
//
// This file is part of miband.
//
// miband is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// miband is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// Connection state, battery/device metadata (M4), and HealthKit sync
// status. Replaces the raw-log-as-primary-view from the old ContentView
// (log itself moves to Settings, Task 11).

import SwiftUI
import HealthKit

struct DashboardView: View {
    @EnvironmentObject private var session: BandSession
    let healthStore: HKHealthStore

    @State private var syncedCount = 0
    @State private var lastSyncedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manumit").font(.largeTitle.bold())
            Text("State: \(session.state.label)").font(.headline)

            if case .failed(let reason) = session.state {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            Divider()
            Text("Sync").font(.headline)
            if let lastSyncedAt {
                Text("Last synced \(lastSyncedAt.formatted()), \(syncedCount) day(s) written")
            } else {
                Text("No sync yet")
            }

            Spacer()
        }
        .padding()
        .onAppear {
            if BandSession.hasSavedPeripheral || true { // scanning-if-not-saved is BandSession's own concern
                // auth key is guaranteed present by onboarding (Task 8) before this view exists
            }
            session.onDailySummaryParsed = { record in
                guard LocalStore.shared.upsert(record) else { return }
                HealthKitStore.save(record, store: healthStore) { success in
                    if success {
                        syncedCount += 1
                        lastSyncedAt = Date()
                    }
                }
            }
            if let key = KeychainStore.load(account: "auth-key"), session.state == .idle {
                session.start(secretKeyHex: key)
            }
        }
    }
}
```

- [ ] **Step 4: Wire `MainTabView` into `ManumitApp.swift`**

In `ManumitApp.swift` (Task 8 Step 3), replace the placeholder line:

```swift
                Text("Main app lands in Task 9") // Task 9 Step 4 replaces this with MainTabView()
```

with:

```swift
                MainTabView()
```

- [ ] **Step 5: Add the two new files to the Xcode project**

`MainTabView.swift`: fileRef `BB0000000000000000000105`, buildFile `BB0000000000000000000205`.
`DashboardView.swift`: fileRef `BB0000000000000000000106`, buildFile `BB0000000000000000000206`.
Both added to `Manumit` group + app `Sources` phase.

- [ ] **Step 6: Push, confirm CI `build` and `test` jobs are both green**

- [ ] **Step 7: Commit**

```bash
git add ios/Manumit/Manumit/MainTabView.swift ios/Manumit/Manumit/DashboardView.swift ios/Manumit/Manumit/BandSession.swift ios/Manumit/Manumit/ManumitApp.swift ios/Manumit/Manumit.xcodeproj
git commit -m "$(cat <<'EOF'
ios/Manumit: tab shell + dashboard + HealthKit sync wiring

Auto-connects on appear, shows battery/device state, and pipes every
parsed daily summary through LocalStore (dedupe) into HealthKit.
EOF
)"
```

---

## Task 10: SystemView

The System tab: toggle built-in apps/widgets on/off, list and delete installed QuickApps.

**Files:**
- Create: `ios/Manumit/Manumit/SystemView.swift`
- Modify: `ios/Manumit/Manumit/MainTabView.swift`
- Modify: `ios/Manumit/Manumit.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `SystemCommandService` (Task 7), injected via `@EnvironmentObject` from `MainTabView` (Task 9).

No new pure logic — manually verified at the final hardware checkpoint.

- [ ] **Step 1: Create `SystemView.swift`**

```swift
// Copyright (C) 2026 miband contributors
//
// This file is part of miband.
//
// miband is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// miband is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// Hide/show built-in apps (System.displayItems) and list/delete
// QuickApps (Rpk) -- specific, mapped actions, not a raw command console
// (spec non-goal).

import SwiftUI

struct SystemView: View {
    @EnvironmentObject private var commands: SystemCommandService
    @EnvironmentObject private var session: BandSession

    var body: some View {
        List {
            Section("Apps & widgets on the band") {
                ForEach(commands.displayItems, id: \.code) { item in
                    Toggle(item.name.isEmpty ? item.code : item.name, isOn: Binding(
                        get: { !item.disabled },
                        set: { enabled in
                            var updated = commands.displayItems
                            guard let idx = updated.firstIndex(where: { $0.code == item.code }) else { return }
                            updated[idx].disabled = !enabled
                            commands.setDisplayItems(updated)
                        }
                    ))
                }
            }
            Section("Installed QuickApps") {
                ForEach(commands.installedApps, id: \.id) { app in
                    HStack {
                        Text(app.name.isEmpty ? app.id : app.name)
                        Spacer()
                        Button("Delete", role: .destructive) {
                            commands.deleteRpk(id: app.id, sha: app.sha)
                        }
                    }
                }
            }
        }
        .onAppear {
            guard session.state == .authenticated else { return }
            commands.getDisplayItems()
            commands.getRpkList()
        }
    }
}
```

- [ ] **Step 2: Add the System tab to `MainTabView`**

In `MainTabView.swift`, replace the `// Task 10 adds a System tab here...` comment with:

```swift
            SystemView()
                .environmentObject(systemCommands)
                .environmentObject(session)
                .tabItem { Label("System", systemImage: "app.badge") }
            // Task 11 adds a Settings tab here.
```

- [ ] **Step 3: Add the file to the Xcode project**

fileRef `BB0000000000000000000107`, buildFile `BB0000000000000000000207`, `Manumit` group + app `Sources` phase.

- [ ] **Step 4: Push, confirm CI `build` and `test` jobs are both green**

- [ ] **Step 5: Commit**

```bash
git add ios/Manumit/Manumit/SystemView.swift ios/Manumit/Manumit/MainTabView.swift ios/Manumit/Manumit.xcodeproj
git commit -m "$(cat <<'EOF'
ios/Manumit: System tab UI (hide apps, delete QuickApps)
EOF
)"
```

---

## Task 11: SettingsView + delete ContentView

Migrates the old single-screen `ContentView`'s remaining functionality (auth key re-entry, raw log, fixture export) into a proper Settings tab, adds "forget device", and deletes the now-unused `ContentView.swift`.

**Files:**
- Create: `ios/Manumit/Manumit/SettingsView.swift`
- Modify: `ios/Manumit/Manumit/MainTabView.swift`
- Delete: `ios/Manumit/Manumit/ContentView.swift`
- Modify: `ios/Manumit/Manumit.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `BandSession` (`.log`, `.fixtureURL`, `.state`), `KeychainStore` (`save`/`load`/`delete`), `BandSession.savedPeripheralAccount`.

No new pure logic — manually verified at the final hardware checkpoint.

- [ ] **Step 1: Create `SettingsView.swift`**

```swift
// Copyright (C) 2026 miband contributors
//
// This file is part of miband.
//
// miband is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// miband is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// Auth key re-entry, "forget device", fixture export, and the raw
// session log -- the leftover debug affordances from the old
// ContentView (deleted alongside this file), relocated here.
// CLAUDE.md's instrumentation rule (fixture logging) stays mandatory;
// it's just not the home-screen UI anymore.

import SwiftUI

private let keychainAccount = "auth-key"

struct SettingsView: View {
    @EnvironmentObject private var session: BandSession
    @State private var authKeyHex = KeychainStore.load(account: keychainAccount) ?? ""

    var body: some View {
        Form {
            Section("Auth key") {
                SecureField("MIBAND_AUTH_KEY", text: $authKeyHex)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Save") {
                    KeychainStore.save(authKeyHex, account: keychainAccount)
                }
                .disabled(authKeyHex.count != 32)
            }

            Section("Device") {
                Button("Forget this band", role: .destructive) {
                    KeychainStore.delete(account: BandSession.savedPeripheralAccount)
                }
            }

            if let fixtureURL = session.fixtureURL {
                Section("Fixture") {
                    ShareLink("Export fixture (\(fixtureURL.lastPathComponent))", item: fixtureURL)
                }
            }

            Section("Log") {
                ScrollView {
                    Text(session.log.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 300)
            }
        }
    }
}
```

- [ ] **Step 2: Add the Settings tab to `MainTabView`**

In `MainTabView.swift`, replace the `// Task 11 adds a Settings tab here.` comment with:

```swift
            SettingsView()
                .environmentObject(session)
                .tabItem { Label("Settings", systemImage: "gear") }
```

- [ ] **Step 3: Add `SettingsView.swift`, remove `ContentView.swift`, from the Xcode project**

Add: fileRef `BB0000000000000000000108`, buildFile `BB0000000000000000000208`, `Manumit` group + app `Sources` phase.

Remove `ContentView.swift`'s entries entirely: delete its `PBXFileReference` (`BB0000000000000000000012`), its `PBXBuildFile` (`BB0000000000000000000022`), its line in the app's `Sources` phase `files`, and its line in the `Manumit` group's `children`.

- [ ] **Step 4: Delete the file**

```bash
rm ios/Manumit/Manumit/ContentView.swift
```

- [ ] **Step 5: Push, confirm CI `build` and `test` jobs are both green**

- [ ] **Step 6: Commit**

```bash
git add -A ios/Manumit/Manumit/SettingsView.swift ios/Manumit/Manumit/MainTabView.swift ios/Manumit/Manumit/ContentView.swift ios/Manumit/Manumit.xcodeproj
git commit -m "$(cat <<'EOF'
ios/Manumit: Settings tab, retire ContentView

Auth key re-entry, forget-device, fixture export, and the raw log move
from the old single debug screen into a proper Settings tab. This was
the last consumer of ContentView.swift -- deleted.
EOF
)"
```

---

## Task 12: Final hardware checkpoint

Per the spec: one combined test, no intermediate stops. This is a manual verification task, not code — sideload the build produced by `.github/workflows/manumit-ipa.yml` and confirm all four behaviors from the design doc.

**Files:** none (verification only).

- [ ] **Step 1: Trigger the IPA build**

Push the final commit (or run `workflow_dispatch` on `manumit-ipa.yml`), download the `Manumit-unsigned` artifact.

- [ ] **Step 2: Sideload via AltStore/SideStore**

- [ ] **Step 3: Verify onboarding + auto-connect**

Fresh install (no Keychain data): app shows the auth-key entry screen, then the HealthKit prompt, then lands on Dashboard, which auto-connects to the band without further input.

- [ ] **Step 4: Verify Dashboard metadata**

Battery level/state visible (M4 behavior, unchanged).

- [ ] **Step 5: Verify HealthKit sync**

After a sync completes, open the Health app and confirm steps, active/basal energy, and heart rate (min/max/avg/resting) samples appear for the current day, sourced from Manumit.

**If this step fails specifically due to HealthKit authorization being silently denied/unavailable under the sideload signing identity:** this is the structural risk flagged in the Global Constraints section. Stop and report it — do not add a workaround (e.g. writing health data somewhere else instead) without discussing it first.

- [ ] **Step 6: Verify System tab**

Toggle a built-in app off in the System tab; confirm it disappears from the band's own launcher/widget screen. Delete a QuickApp (if any are installed beyond the bundled `com.xiaomi.smarthome.watch`); confirm it disappears from the band and from the list on next `RPK_LIST` refresh.

- [ ] **Step 7: Report results**

All four (dashboard, HealthKit, system-hide, system-delete) must work for this milestone to be done, per the spec's testing section. Partial success is reported as partial, not rounded up.
