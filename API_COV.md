# Swift API coverage over the native room backend

Checkpoint: production Room integration against Rust `893bc21b328adaa1d00eb036ded59bad415e8890`
(shipped FFI 0.13.4 baseline). Package:
`/Users/blaze/livekit/research-v3/rust-ffi/room-apis-893bc21b/livekit-ffi-xcframework`.
Framework SHA-256: `702a7ad86fe5fa16cedcac4b747f2f1c184d7b6a569a7c53d720eca443c4dc28`.
Only macOS arm64 is supplied. No stand-in exports or second room engine.

**Conclusion:** native helper exports are available and the production Room/data
path has real two-room proof. **Drop-in/minor-version compatibility is not established
and currently fails known behavioral/platform requirements.** Media integration is
pending. Independent Claude review is still required before acceptance.

`implemented` means working-backend/PoC behavior exercised by the evidence below,
not minor-version compatibility; `pending` means
native support still needs Swift integration/verification; `compile-only` means
the public declaration remains without equivalent native behavior; `blocked`
means the required native/core access is absent. Throwing unsupported activation
fails with LiveKitError; nonthrowing APIs cannot provide that failure contract.

## Acceptance gates (separate from working-backend proof)

| Gate | Current conclusion |
|---|---|
| Public Swift/ObjC declarations, enum values, selectors, availability | macOS Release/distribution build at `85e6f807`: digester reports zero breaking changes and zero additions. ObjC header differs only by relocating the unchanged Room.prepareConnection category; exact header line multiset is equal. Enum/selector/availability text is unchanged. This is surface evidence, not behavioral compatibility. |
| Existing unmodified public E2E | 21 existing Objective-C test methods passed unchanged, including streams/file/incremental writers, data tracks, RPC and Room delegates. Swift subset uses explicitly adapted plaintext/no-statistics fixtures and is **not** unchanged-app acceptance. |
| Lifecycle/default/error/delegate/observation semantics | Two-room state/delegate/data/rejoin, invalid-token, cancellation and release proof exists. Involuntary reconnect, full error parity, observation ordering and default-option parity remain unproved. New unsupported throws and ineffective nonthrowing controls are **compatibility breaks**. |
| Supported build/package/target matrix | macOS arm64 Debug tests and Release/distribution build passed; iOS/Catalyst/tvOS/visionOS slices absent. Absolute local artifact pin is research packaging, not a distributable minor release. |

## Single capability/blocker ledger

| Swift API / behavior | Native support and Swift status | Evidence / remaining work |
|---|---|---|
| `Room.connect(url:token:connectOptions:roomOptions:) async throws`, `disconnect() async` | **implemented**, native session is the active connection owner. Swift signaling/Transport connection orchestration removed. | `NativeRoomTests.productionRoomLifecycle`, invalid-token/cancellation and release tests. Explicit disconnect/rejoin tested; involuntary network recovery not yet proved. |
| `Room.remoteParticipants`, `localParticipant`, metadata/state getters and delegates | **implemented** for room and participant state. Native records feed existing nanopb/entity setters and StateSync; identity retains the same RemoteParticipant across updates. | Two-room membership, name/metadata/attributes updates, departure and rejoin. Media publication records are projected; media Track handles remain absent. |
| `LocalParticipant.publish(data:options:) async throws` | **implemented**, `NativeRoomSession.publishData(payload:options:)`. | Existing `PublishDataTests`: both permission cases, 100 reliable topics each. Native data-channel buffer-status callbacks are not exported. |
| `LocalParticipant.set(name:)`, `set(metadata:)`, `set(attributes:)` | **implemented**, native typed commands. | Production two-room update/identity test. |
| `sendText`, `sendBytes`, `sendFile`, `streamText`, `streamBytes`; byte/text reader/writer APIs | Native handles and room commands **available**; plaintext text/bytes/file/incremental variants **implemented** in production. Progress-specific Swift acceptance remains pending. | `NativeRoomTests` text and byte round trips; existing DataStreamObjCTests proves file, text and incremental byte/text writers. Native milestone README also proves all five commands. No old packet managers. |
| Internal `DataStreams.registerTextStreamHandler(for:ordered:_:) throws` used by ordered chat/transcription consumers | **blocked** in this artifact: no stream-close event/independent close wait. `ordered: true` rejects explicitly. | Rust owner reports an additive `waitClosed()` in an uncommitted next milestone; do not claim it for 893bc21b. Public unordered stream handlers work. |
| `LocalParticipant.publishDataTrack(name:options:)`, `defineSchema(_:definition:)`, `getSchema(_:publishedBy:)`; data-track handles | **implemented**, native room commands and existing generated handle shapes. | Existing DataTrackApiTests, schema round-trip/missing-schema tests, timestamp/resubscribe/published-state tests. Buffering, frames and unpublish use Rust directly. |
| `LocalDataTrack.send(contentsOf:) async throws` | Real native `tryPush` path; **not fully verified** under burst loss. | Broader run failed the existing minimum-received-frame assertion; no reliability guarantee added to this unreliable transport. Paced/reassembly tests passed. |
| `Room.registerRpcMethod`, `unregisterRpcMethod`, `isRpcMethodRegistered`; `LocalParticipant.performRpc(...)` | Native RPC operations **available**, production echo/rejoin **implemented**. Native reply handles preserve errors; Swift handler tasks cancel on disconnect. | Production two-room echo/rejoin test. Deadline, pending-reply disconnect and custom-error Swift acceptance remain pending (native milestone has its own proof). |
| `Participant.capabilities: [ClientCapability]`, `clientProtocol` | Remote capabilities now mapped; local capabilities **compile-only** because native local snapshot is nil. Nondefault connect clientProtocol rejects (no option export). | No longer a missing remote-field/helper blocker. Core negotiates native sends. |
| Token/log helpers (`Claims`, `TokenOptions`, inference/observability grants, `logForwardBootstrap`, `logForwardReceive`) | **available**, compatible generated 0.13.4 shapes; production compiles without replacement types. | Real token generation exercised by all integration fixtures. Old missing-export claims resolved. |
| Media publish/subscribe and `TrackPublication.track` | **pending** native media milestone. Public Room/Participant/TrackPublication/Track NSObject hierarchy retained. Media publication, subscription control and track-setting activation reject. | 893bc21b exports publication records, not usable native audio/video handles. No Swift peer connection is created by Room. |
| `RemoteTrackPublication.set(preferredFPS:)`, `RemoteAudioTrack.volume` | FPS control and per-track volume **blocked** on core/export support; volume is nonthrowing and **compile-only** for native media. | Requires actual controls, not fake setters. |
| `AudioManager.setManualRenderingMode(_:)`, graph observers/mixer/custom-processing delegates | AVAudioEngine graph access **blocked** while Rust owns the device; manual-rendering activation throws. Nonthrowing graph interfaces are **compile-only**. | Exposing/owning the real graph would require a separate audio-device design; no large adapter added. |
| `AudioManager.setPlatformVoiceProcessingAllowed(_:)`, `LocalAudioTrack.setAudioProcessingOptions(_:)`, voice processing/AGC controls | **pending mapping**, not inherently impossible. Current throwing activation rejects because this artifact supplies no native mapping. Nonthrowing controls are **compile-only** for native media. | Distinguish core-supported processing controls from graph-access blockers; validate the actual next media exports before wiring. |
| Room encryption options / `setE2EEEnabled(_:)` | **blocked in this artifact**. Encryption options reject at connect. Nonthrowing enable request is logged and blocks subsequent outgoing command activation; it does not retrofit open handles. | Audio/video/data E2EE needs real native configuration. Encrypted data-track assertions are not plaintext acceptance tests. |
| `Room.serverVersion`, `serverRegion`, `serverNodeId` | **compile-only**, nil: native snapshots omit server info. | Needs native/core metadata access. |
| `Room.connect`/stream command error types | **compatibility unresolved**: `NativeSessionError.Connection(reason:)` / `Request(reason:)` erase structured status/cause information. | Native structured connection/HTTP and stream-command errors are needed for exact LiveKitError/StreamError parity; no parsing of display strings. |
| `Room.prepareConnection(url:token:)` and region preparation | Declaration retained; prepared-region/cache consumption is **pending** on the native connect path. | Native connection/region policy must expose the equivalent behavior; do not count retained Swift preparation code as parity. |
| `Room.debug_simulate(scenario:)` | Unsupported activation throws. | No native simulation command exported. |
| iOS, Catalyst, tvOS, visionOS | **blocked for execution** by this macOS-only artifact. Declarations remain. | Need exact platform slices; iOS API comparison cannot be claimed from a macOS build. |

## Connection option contract

Mapped: autoSubscribe, adaptiveStream, dynacast, singlePeerConnection,
socketConnectTimeoutInterval and dataStreamOptions.maxPayloadByteLength (validated
UInt32 range). Nondefault retry count/delays, per-transport timeouts, ICE servers,
ICE policy, DSCP, protocolVersion, clientProtocol, microphone activation, encryption
and remote media-statistics activation reject until exported/mapped.

Observed default behavior differences (not accepted as minor-version compatible): Rust owns retry/backoff/ICE timing and
signaling sockets/TLS; core signaling protocol is 17 versus Swift's legacy 16.
Cancellation uses deferred native cancellation/cleanup, never synchronous native
`cancel()` inside a Swift `onCancel` handler.

## Verification and compatibility

Evidence: `/Users/blaze/livekit/research-v3/swift-native-next/`.
`production-tests-final.log`: **18 test functions / 18 cases passed** (six suites).
The external test manifest compiles all production sources unchanged via symlinks
and selected repository tests. Its copied test fixtures disable default E2EE and
remote statistics only; no production/native stand-ins. Obsolete internal-manager
tests require migration and are not counted as passing.

`production-tests-7.log` preserves broader-run failures: two encrypted-frame cases
and one unreliable sequence-send assertion. `production-test-4.log` is the first
production Room connection/data/RPC/text/bytes/rejoin proof. `objc-final.log`: **21 Objective-C test methods/cases passed**, all seven existing
ObjC files unchanged. Final Release API output is `api-final/macOS/` with exact source/package tree hashes
and compiler target in `provenance.txt`. `api-compare-final.log` contains the
comparison; `objc-header.diff` contains only category relocation. A focused
post-API Swift follow-up passed **4 functions / 4 cases** in
`production-post-api.log` (`NativeRoomTests|NativeRoomProtoTests`).
No baseline suite rerun. Independent Claude review remains pending.

Public baseline: Swift `2fcaec9c` / v2.20.0, read-only dumps and Objective-C headers
at `/Users/blaze/livekit/research-v3/swift-baseline`. Comparison uses `.github/api-check/api-dump.sh` after the real backend build.
No iOS dump was produced: this native package has no iOS slice.

Verification commands (all local, at most two build jobs):

```sh
LIVEKIT_TESTING_URL=ws://127.0.0.1:17891 swift test --jobs 2 --package-path /Users/blaze/livekit/research-v3/swift-native-next/production-check --filter 'NativeRoomTests|NativeRoomProtoTests|PublishDataTests|DataTrackApiTests|defineAndGetSchema|getUndefinedSchemaThrows|frameTimestamp|resubscribe|publishedState'
# In research-v3/swift-native-next/production-check:
LIVEKIT_TESTING_URL=ws://127.0.0.1:17891 TEST_RUNNER_LIVEKIT_TESTING_URL=ws://127.0.0.1:17891 xcodebuild test -scheme LiveKit -destination 'platform=macOS' -jobs 2 -only-testing:LiveKitObjCTests -derivedDataPath /Users/blaze/livekit/research-v3/swift-native-next/objc-dd -resultBundlePath /Users/blaze/livekit/research-v3/swift-native-next/objc-final.xcresult
# In the owned Swift worktree:
JOBS=2 CACHE=/Users/blaze/livekit/research-v3/swift-native-next/api-cache .github/api-check/api-dump.sh /Users/blaze/livekit/research-v3/swift-native-next/api-final macOS
.github/api-check/api-dump.sh --diff /Users/blaze/livekit/research-v3/swift-baseline/macOS /Users/blaze/livekit/research-v3/swift-native-next/api-final/macOS
```

Swift test files: NativeRoomTests.swift, NativeRoomProtoTests.swift,
PublishDataTests.swift, DataTrack/DataTrackApiTests.swift, selected functions in
DataTrack/DataTrackPublishTests.swift and DataTrack/DataTrackTests.swift (all under
Tests/LiveKitCoreTests). ObjC: all seven files in Tests/LiveKitObjCTests.
Lint: `swiftlint lint --strict` on the exact 20-file list in the external
`touched-swift-files.txt`; targeted resilience/header fixes also have lint logs.

Follow-up data-path checks (893 artifact, no SDK source/API changes):
`NativeRoomTests.participantObservationAndCallbackOrder` and
`rpcErrorsDeadlineAndCancellation`: **2 functions / 2 cases passed**. Identity,
synchronous getters inside name callbacks, ordered sequential name callbacks,
SwiftUI notification delivery, custom RPC code/message/data, unsupported-method
code, response deadline, cancellation and a subsequent RPC are covered. Baseline
`2fcaec9c` participant observer implementation and existing RPC assertions were
compared read-only; no baseline runtime rerun. This is plaintext data-path proof.
Command: `LIVEKIT_TESTING_URL=ws://127.0.0.1:17891 swift test --jobs 2 --package-path /Users/blaze/livekit/research-v3/swift-native-next/production-check --filter 'participantObservationAndCallbackOrder|rpcErrorsDeadlineAndCancellation'`.
Evidence: `observation-rpc-final.log`, `observation-lint.log` in the evidence root.
