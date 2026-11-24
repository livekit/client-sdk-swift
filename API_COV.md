# Swift API coverage over the native room backend

Checkpoint: production Room and media integration against committed Rust
`c6f070e0cd30bdc77fec86ca206c214941e49f73` (shipped FFI 0.13.4 baseline).
Package: `/Users/blaze/livekit/research-v3/rust-ffi/room-apis-c6f070e0/livekit-ffi-xcframework`.
Verified framework SHA-256: `26f6630b5bb0f25b879db407d8e1808d06da695fb7e8776a0a6aec3c594cc5fd`.
The consumed XCFramework is macOS arm64. Owner also compiled raw iOS device
(minOS13) and arm64 simulator (minOS14) dylibs; these are not yet packaged or
validated in Swift. No stand-in exports, second Room engine or Swift peer connection.

**Conclusion:** production encrypted connection, microphone/synthetic PCM,
buffer-video capture and remote `VideoView` rendering work through Rust.
Original unchanged shared-key/statistics-enabled participant fixtures now pass.
**Drop-in/minor-version compatibility remains unestablished.** Camera runtime
capture timed out; speaker playback, complete metadata/errors/options and other
Apple targets are not accepted. Independent Claude review remains required.

`implemented` means working-backend/PoC behavior exercised by the evidence below,
not minor-version compatibility; `pending` means
native support still needs Swift integration/verification; `compile-only` means
the public declaration remains without equivalent native behavior; `blocked`
means the required native/core access is absent. Throwing unsupported activation
fails with LiveKitError; nonthrowing APIs cannot provide that failure contract.

## Acceptance gates (separate from working-backend proof)

| Gate | Current conclusion |
|---|---|
| Public Swift/ObjC declarations, enum values, selectors, availability | macOS Release/distribution build at `42e475cb`: digester reports zero breaking changes and zero additions. ObjC header differs only by relocating the unchanged Room.prepareConnection category; exact header line multiset is equal. Enum/selector/availability text is unchanged. This is surface evidence, not behavioral compatibility. |
| Existing unmodified public E2E | 21 existing Objective-C test methods passed unchanged, including streams/file/incremental writers, data tracks, RPC and Room delegates. Current participant identity/membership, PublishDataTests and DataTrackApiTests also pass with original unchanged shared-key/statistics-enabled fixtures; this does not imply all defaults/media statistics work. |
| Lifecycle/default/error/delegate/observation semantics | Two-room state/delegate/data/rejoin, invalid-token, cancellation and release proof exists. Sequential name callback ordering/getter consistency and SwiftUI notification delivery now pass. Involuntary reconnect, full error parity and default-option parity remain unproved. New unsupported throws and ineffective nonthrowing controls are **compatibility breaks**. |
| Supported build/package/target matrix | macOS arm64 Debug tests and Release/distribution build passed; iOS/Catalyst/tvOS/visionOS packaged slices absent. Absolute local artifact pin is research packaging, not a distributable minor release. |

## Single capability/blocker ledger

| Swift API / behavior | Native support and Swift status | Evidence / remaining work |
|---|---|---|
| `Room.connect(url:token:connectOptions:roomOptions:) async throws`, `disconnect() async` | **implemented**, native session is the active connection owner. Swift signaling/Transport connection orchestration removed. | `NativeRoomTests.productionRoomLifecycle`, invalid-token/cancellation and release tests. Explicit disconnect/rejoin tested; involuntary network recovery not yet proved. |
| `Room.remoteParticipants`, `localParticipant`, metadata/state getters and delegates | **implemented** for room and participant state. Native records feed existing nanopb/entity setters and StateSync; identity retains the same RemoteParticipant across updates. | Two-room membership, name/metadata/attributes updates, departure and rejoin. Media publication records are projected; native audio/video Track handles attach to the same publications. |
| `LocalParticipant.publish(data:options:) async throws` | **implemented** payload delivery, `NativeRoomSession.publishData(payload:options:)`; encryption metadata remains incorrect/incomplete in the legacy callback. | Existing `PublishDataTests`: both permission cases, 100 reliable topics each. Native data-channel buffer-status callbacks are not exported. Core drops packet encryption type: legacy callback still receives `.none`, which is **not authoritative** for encrypted payloads (one warning per connection). No `.gcm` inference or metadata-parity claim. |
| `LocalParticipant.set(name:)`, `set(metadata:)`, `set(attributes:)` | **implemented**, native typed commands. | Production two-room update/identity test. |
| `sendText`, `sendBytes`, `sendFile`, `streamText`, `streamBytes`; byte/text reader/writer APIs | Native handles and room commands **available**; plaintext text/bytes/file/incremental variants **implemented** in production. Progress-specific Swift acceptance remains pending. | `NativeRoomTests` text and byte round trips; existing DataStreamObjCTests proves file, text and incremental byte/text writers. Native milestone README also proves all five commands. No old packet managers. |
| Internal `DataStreams.registerTextStreamHandler(for:ordered:_:) throws` used by ordered chat/transcription consumers | **blocked**: c6 provides independent `waitClosed()` but not causal close/open order. Baseline overlapping streams must remain concurrent; all-stream serialization breaks that contract. | Core `room/mod.rs:2497` ignores `OutputEvent::StreamClosed`; requires ordered `RoomEvent::StreamClosed(id,identity)`. Independently scheduled completion tasks cannot establish wire ordering. Public unordered handlers work. |
| `LocalParticipant.publishDataTrack(name:options:)`, `defineSchema(_:definition:)`, `getSchema(_:publishedBy:)`; data-track handles | **implemented**, native room commands and existing generated handle shapes. | Existing DataTrackApiTests, schema round-trip/missing-schema tests, timestamp/resubscribe/published-state tests. Buffering, frames and unpublish use Rust directly. |
| `LocalDataTrack.send(contentsOf:) async throws` | Real native `tryPush` path; **not fully verified** under burst loss. | Broader run failed the existing minimum-received-frame assertion; no reliability guarantee added to this unreliable transport. Paced/reassembly tests passed. |
| `Room.registerRpcMethod`, `unregisterRpcMethod`, `isRpcMethodRegistered`; `LocalParticipant.performRpc(...)` | Native RPC operations **available**, production echo/rejoin **implemented**. Native reply handles preserve errors; Swift handler tasks cancel on disconnect. | Production echo/rejoin plus custom code/message/data, unsupported method, response deadline, cancellation and subsequent-call tests pass. Pending-reply disconnect remains pending. |
| `Participant.capabilities: [ClientCapability]`, `clientProtocol` | Remote capabilities now mapped; local capabilities **compile-only** because native local snapshot is nil. Nondefault connect clientProtocol rejects (no option export). | No longer a missing remote-field/helper blocker. Core negotiates native sends. |
| Token/log helpers (`Claims`, `TokenOptions`, inference/observability grants, `logForwardBootstrap`, `logForwardReceive`) | **available**, compatible generated 0.13.4 shapes; production compiles without replacement types. | Real token generation exercised by all integration fixtures. Old missing-export claims resolved. |
| Media publish/subscribe and `TrackPublication.track` | **implemented working path**: native source/publication handles attach to existing NSObject tracks; remote PCM/video sinks feed AudioRenderer/VideoView; mute/unmute/unpublish/unsubscribe route native. | Swift encrypted synthetic PCM + physical microphone + buffer video/VideoView pass, including initial publication snapshot and identity across mute. Camera route wired, but default and built-in camera capture both timed out before dimensions. Speaker playback unproved. Custom encoding/processing options reject pending mappings. |
| `RemoteTrackPublication.set(preferredFPS:)`, `RemoteAudioTrack.volume` | FPS control and per-track volume **blocked** on core/export support; volume is nonthrowing and **compile-only** for native media. | Requires actual controls, not fake setters. |
| `AudioManager.setManualRenderingMode(_:)`, graph observers/mixer/custom-processing delegates | AVAudioEngine graph access **blocked** while Rust owns the device; manual-rendering activation throws. Nonthrowing graph interfaces are **compile-only**. | Exposing/owning the real graph would require a separate audio-device design; no large adapter added. |
| `AudioManager.setPlatformVoiceProcessingAllowed(_:)`, `LocalAudioTrack.setAudioProcessingOptions(_:)`, voice processing/AGC controls | **pending mapping**, not inherently impossible. Current throwing activation rejects because this artifact supplies no native mapping. Nonthrowing controls are **compile-only** for native media. | Distinguish core-supported processing controls from graph-access blockers; validate the actual next media exports before wiring. |
| Room encryption options / `setE2EEEnabled(_:)` | **implemented shared-key index-zero configuration**: BaseKeyProvider retains the actual native provider across the session, forwards key updates/export/ratchet; Room connects with native data+media or legacy media-only encryption. Callbacks remain incomplete. | Core `RoomEvent::DataReceived` at `room/mod.rs:207` drops per-packet encryption despite `handle_data` receiving it at 1846–1874. Core `E2eeStateChanged` at :252 lacks track SID (`e2ee/manager.rs:204–210` discards it). Require per-packet encryption and track-associated events upstream; cannot infer from mutable participant/config or fan out a guessed publication. Independent current-key-index/media-data dynamic-toggle parity absent. Unsupported nonthrowing switches log/reject activation rather than claim a native change; these are compatibility breaks. Per-participant/multi-index custom-provider parity is unproved. |
| `RoomOptions.reportRemoteTrackStatistics`, `Track.statistics` | Setting retained in Room/Track state and no longer blocks connections; **sample polling pending** typed native `getStatistics()` artifact. | Core get_stats is accessible; additive FFI mapping requested, not an architectural blocker. No invented samples or false statistics proof. |
| `Room.serverVersion`, `serverRegion`, `serverNodeId` | **compile-only**, nil: native snapshots omit server info. | Needs native/core metadata access. |
| `Room.connect`/stream command error types | **compatibility unresolved**: `NativeSessionError.Connection(reason:)` / `Request(reason:)` erase structured status/cause information. | Native structured connection/HTTP and stream-command errors are needed for exact LiveKitError/StreamError parity; no parsing of display strings. |
| `Room.prepareConnection(url:token:)` and region preparation | Declaration retained; prepared-region/cache consumption is **pending** on the native connect path. | Native connection/region policy must expose the equivalent behavior; do not count retained Swift preparation code as parity. |
| `Room.debug_simulate(scenario:)` | Unsupported activation throws. | No native simulation command exported. |
| iOS, Catalyst, tvOS, visionOS | **blocked for execution** by this macOS-only artifact. Declarations remain. | Need exact platform slices; iOS API comparison cannot be claimed from a macOS build. |

## Connection option contract

Mapped: autoSubscribe, adaptiveStream, dynacast, singlePeerConnection,
socketConnectTimeoutInterval and dataStreamOptions.maxPayloadByteLength (validated
UInt32 range). Nondefault retry count/delays, per-transport timeouts, ICE servers,
ICE policy, DSCP, protocolVersion, clientProtocol and connect-time microphone activation reject until exported/mapped. Shared-key encryption and public setMicrophone are now mapped. Remote statistics is retained, with real polling pending the next export.

Observed default behavior differences (not accepted as minor-version compatible): Rust owns retry/backoff/ICE timing and
signaling sockets/TLS; core signaling protocol is 17 versus Swift's legacy 16.
Cancellation uses deferred native cancellation/cleanup, never synchronous native
`cancel()` inside a Swift `onCancel` handler.

## Verification and compatibility

Evidence: `/Users/blaze/livekit/research-v3/swift-native-next/`.
`production-tests-final.log`: **18 test functions / 18 cases passed** (six suites).
The external test manifest compiles all production sources unchanged via symlinks
and selected repository tests. For that run its copied test fixtures disabled default E2EE and
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

Current media evidence (same external evidence root): `media-regression-final.log`
passed 19 executed test functions / 20 cases; camera function is separately gated
by `LIVEKIT_TESTING_CAMERA=1` and was not counted as passing. Files: NativeRoomTests.swift,
NativeMediaTests.swift, NativeRoomProtoTests.swift, ParticipantTests.swift (identity,
membership), PublishDataTests.swift, DataTrackApiTests.swift. Original support
fixtures are unchanged (`c6-fixture-provenance.txt`). Command:
`LIVEKIT_TESTING_URL=ws://127.0.0.1:17891 swift test --jobs 2 --package-path /Users/blaze/livekit/research-v3/swift-native-next/production-check --filter 'NativeRoomTests|NativeRoomProtoTests|localParticipantIdentity|remoteParticipants|PublishDataTests|DataTrackApiTests'`.
`media-mic.log` and `media-video.log` retain first encrypted media proofs.
`media-camera-final.log` and `media-camera-builtin.log` preserve camera capture
timeouts; no camera frames/images retained. Earlier `c6-default-fixtures.log`
activation failures are superseded by the implemented encryption path, not hidden.

Cancellation baseline limitation: exact shipped FFI0.13.4 reader cancellation
reproduces the same two continuation-storage TSan signatures (120 cancellation
iterations); matched 120 reads without task cancellation report none. This is
not migration-specific evidence and does not establish safety/fix. Deferred
cancellation/cleanup remains; no dependency upgrade. Evidence:
`/Users/blaze/livekit/research-v3/current-cancellation/baseline/REPORT.md`.

Media checkpoint final verification: Release/distribution build and saved
`api-media-final/macOS` at `42e475cb` report zero API changes/additions;
Objective-C header hash remains `6819645bdc9f8c4b829736946aa1cc2321eb037dead76697855396b7559a0bdc`.
`objc-media.log`/`objc-media.xcresult`: all 21 unchanged methods/cases pass.
Commands are the same API/ObjC commands above with output names `api-media-final`
and `objc-media`. `media-post-api.log`: three functions / four cases pass
(encrypted synthetic+physical audio, GCM text/byte stream metadata and RPC,
buffer video/VideoView, disconnect capture cleanup, Room release). No source
changes after the saved API dump; this follow-up adds assertions only.
