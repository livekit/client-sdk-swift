# Swift API coverage over the native room backend

**Review update:** native artifact `b3bf27bb` is not accepted. Its automatic
playout lease can enable microphone capture when a PCM track is published later.
That activation is being removed. Safe receive-only speaker output remains a
core-API gap; the output measurements below cover only the tested event order,
not general capture safety. The Swift and Rust reviews are not yet complete.

Checkpoint: production Room and media integration against committed Rust
`b3bf27bbb6f56c67d4ff136c5c0d67d63cb48e50` (shipped FFI 0.13.4 baseline).
Package: `/Users/blaze/livekit/research-v3/rust-ffi/room-apis-b3bf27bb/livekit-ffi-xcframework`.
Verified framework SHA-256: `bfa3cc20eb2f3eefaaea1b7b43a202ad133d866d420a08e3233662c4d74ac9b9`.
The combined package supplies macOS arm64 and iOS device/simulator arm64;
all three Swift bindings are byte-identical to247. Archive SHA-256:
`ccecaa100ab57650b69e4acd0695bc5869351d4af0f68a3ac046cb597ef8678c`.
Device LC_BUILD_VERSION says13, but linked WebRTC archive members require14:
**no iOS13 compatibility** despite the SDK declaration13. This is a minor-release
blocker. No stand-in exports, second Room engine or Swift peer connection.

**Conclusion:** production encrypted connection, microphone/synthetic PCM,
buffer-video capture and remote `VideoView` rendering work through Rust.
Original unchanged shared-key/statistics-enabled participant fixtures now pass.
**Drop-in/minor-version compatibility remains unestablished.** Camera capture
times out on both baseline and migration. The b3 receive-only output proof is
not accepted after the microphone-activation privacy finding above; safe output
needs a core API. Audible output and iOS runtime remain unverified.
Complete metadata/errors/options and the full Apple target matrix remain gaps. Independent Claude review remains required.

`implemented` means working-backend/PoC behavior exercised by the evidence below,
not minor-version compatibility; `pending` means
native support still needs Swift integration/verification; `compile-only` means
the public declaration remains without equivalent native behavior; `blocked`
means the required native/core access is absent. Throwing unsupported activation
fails with LiveKitError; nonthrowing APIs cannot provide that failure contract.

## Acceptance gates (separate from working-backend proof)

| Gate | Current conclusion |
|---|---|
| Public Swift/ObjC declarations, enum values, selectors, availability | macOS Release/distribution at `626eecdf` and iOS device at `96cddfb0`: digester reports zero breaking changes and zero additions. ObjC header differs only by relocating the unchanged Room.prepareConnection category; exact header line multiset is equal. Enum/selector/availability text is unchanged. This is surface evidence, not behavioral compatibility. |
| Existing unmodified public E2E | 21 existing Objective-C test methods passed unchanged, including streams/file/incremental writers, data tracks, RPC and Room delegates. Current participant identity/membership, PublishDataTests and DataTrackApiTests also pass with original unchanged shared-key/statistics-enabled fixtures; this does not imply all default/media behavior is compatible. |
| Lifecycle/default/error/delegate/observation semantics | Two-room state/delegate/data/rejoin, invalid-token, cancellation and release proof exists. Sequential name callback ordering/getter consistency and SwiftUI notification delivery now pass. Involuntary reconnect, full error parity and default-option parity remain unproved. New unsupported throws and ineffective nonthrowing controls are **compatibility breaks**. |
| Supported build/package/target matrix | macOS arm64 Debug/Release and iOS device Release build/API comparison pass; arm64 simulator Release build passes. Catalyst/tvOS/visionOS/Intel simulator slices absent. Absolute local artifact pin is research packaging, not a distributable minor release. |

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
| `Participant.capabilities: [ClientCapability]`, `clientProtocol` | Remote capabilities now mapped; local capabilities **compile-only** because native local snapshot is nil. Nondefault connect clientProtocol rejects: public core RoomOptions cannot override SignalOptions; the new export accepts only nil/default2. | No longer a missing remote-field/helper blocker. Core negotiates native sends. |
| Token/log helpers (`Claims`, `TokenOptions`, inference/observability grants, `logForwardBootstrap`, `logForwardReceive`) | **available**, compatible generated 0.13.4 shapes; production compiles without replacement types. | Real token generation exercised by all integration fixtures. Old missing-export claims resolved. |
| Media publish/subscribe and `TrackPublication.track` | **implemented working path**: native source/publication handles attach to existing NSObject tracks; remote PCM/video sinks feed AudioRenderer/VideoView; mute/unmute/unpublish/unsubscribe route native. | Swift encrypted synthetic PCM + physical microphone + buffer video/VideoView pass, including initial publication snapshot and identity across mute. Camera capture times out identically on unchanged baseline and migration with the same built-in device/authorization; no migration-specific adapter defect established. The b3 automatic PlatformAudio lease is rejected after the privacy review: its tested event order did not establish general capture safety. Safe receive-only output needs a core API; no acceptance or audible-output claim. Custom encoding/processing options reject pending mappings. |
| `RemoteTrackPublication.set(preferredFPS:)`, `RemoteAudioTrack.volume` | FPS control and per-track volume **blocked** on core/export support; volume is nonthrowing and **compile-only** for native media. | Requires actual controls, not fake setters. |
| `AudioManager.setManualRenderingMode(_:)`, graph observers/mixer/custom-processing delegates | AVAudioEngine graph access **blocked** while Rust owns the device; manual-rendering activation throws. Nonthrowing graph interfaces are **compile-only**. | Exposing/owning the real graph would require a separate audio-device design; no large adapter added. |
| `AudioManager.setPlatformVoiceProcessingAllowed(_:)`, `LocalAudioTrack.setAudioProcessingOptions(_:)`, voice processing/AGC controls | **pending mapping**, not inherently impossible. Current throwing activation rejects because this artifact supplies no native mapping. Nonthrowing controls are **compile-only** for native media. | Distinguish core-supported processing controls from graph-access blockers; validate the actual next media exports before wiring. |
| Room encryption options / `setE2EEEnabled(_:)` | **implemented shared-key index-zero configuration**: BaseKeyProvider retains the actual native provider across the session, forwards key updates/export/ratchet; Room connects with native data+media or legacy media-only encryption. Callbacks remain incomplete. | Core `RoomEvent::DataReceived` at `room/mod.rs:207` drops per-packet encryption despite `handle_data` receiving it at 1846–1874. Core `E2eeStateChanged` at :252 lacks track SID (`e2ee/manager.rs:204–210` discards it). Require per-packet encryption and track-associated events upstream; cannot infer from mutable participant/config or fan out a guessed publication. Independent current-key-index/media-data dynamic-toggle parity absent. Unsupported nonthrowing switches log/reject activation rather than claim a native change; these are compatibility breaks. Per-participant/multi-index custom-provider parity is unproved. |
| `RoomOptions.reportRemoteTrackStatistics`, `Track.statistics` | **implemented** native publication `getStatistics()` polling through existing TrackStatistics models and previous samples. | Encrypted audio/video produce positive sent/received counters; UInt64 above 2^53, id/codecId/SSRC verified. Protobuf default values cannot restore original absent-field optionality. Full sample/default/backup-codec parity remains unproved. |
| `Room.serverVersion`, `serverRegion`, `serverNodeId` | **compile-only**, nil: native snapshots omit server info. | Needs native/core metadata access. |
| `Room.connect`/stream command error types | **implemented typed mapping** for native Signal HTTP source/status/timeout, RequestFailure, RTC and stream IO/cancellation/state variants. | Exact typed permission rejection tested against server, misleading reason strings tested locally. Older reason-only cases and core-erased transport/region causes remain parity gaps; no string parsing. Other public command boundaries still need complete error audit. |
| `Room.prepareConnection(url:token:)` and region preparation | Declaration retained; prepared-region/cache consumption is **pending** on the native connect path. | Native connection/region policy must expose the equivalent behavior; do not count retained Swift preparation code as parity. |
| `Room.debug_simulate(scenario:)` | Unsupported activation throws. | No native simulation command exported. |
| iOS, Catalyst, tvOS, visionOS | Current combined Apple package retains247 bindings; prior production checks: production iOS device Release/API check passes; arm64 simulator Release compile passes. Catalyst/tvOS/visionOS and Intel simulator slices absent. | No iOS runtime claim. Both WebRTC archives have2946 minimum-version commands, all14: device LC13 does NOT establish iOS13 support. SDK declaration13 is a real compatibility blocker. |

Review-specific remaining gaps (existing declarations retained):

| Signature / callback | Status |
|---|---|
| `LocalParticipant.publishDtmf(code:digit:) async throws` | Unsupported native packet activation; needs the core-supported room DTMF export. |
| `LocalParticipant.setTrackSubscriptionPermissions(allParticipantsAllowed:trackPermissions:) async throws` | Unsupported activation; needs native room subscription-permission command. |
| `RemoteTrackPublication.set(videoQuality:) async throws` | Unsupported nondefault quality, separately from FPS; needs publication quality export. |
| `Room.connect(...)` on an already-connected Room | Throws invalidState rather than baseline reconnect behavior; compatibility unresolved. |
| `room(_:participant:trackPublication:didReceiveTranscriptionSegments:)`, internal `room(didReceiveTranscriptionPacket:)`, `room(_:didFailToDecryptDataWithEror:)` | No corresponding native delivery mapping; exact native transcription/decryption events needed. No fabricated callbacks. |
| Per-publication encryption-state callbacks | Native participant/state event lacks track SID; cannot associate truthfully. |
| `DataTrackPublishTests.encryptionToggleAfterConnectApplies` | **Known incompatible, not passed**: calls `setE2EEEnabled(false)` before data-track publication. Dynamic disable remains unsupported; outgoing payload activation rejects. Metadata/name/attributes are unaffected. |

## Connection option contract

Mapped: autoSubscribe, adaptiveStream, dynacast, singlePeerConnection,
socketConnectTimeoutInterval, ICE servers/credentials, all/relay/noHost policy,
clientProtocol2 and dataStreamOptions.maxPayloadByteLength (validated UInt32 range).
Nondefault retry count/delays, per-transport timeouts, ICE none policy, DSCP,
protocolVersion, nondefault clientProtocol and connect-time microphone activation
reject. Shared-key encryption, public setMicrophone and remote statistics polling
are mapped; standalone LocalAudioTrack.start before native publication is still a
compatibility break. Native runtime ICE enforcement needs dedicated TURN proof.

Observed default behavior differences (not accepted as minor-version compatible): Rust owns retry/backoff/ICE timing and
signaling sockets/TLS; core signaling protocol is 17 versus Swift's legacy 16.
Cancellation uses deferred native cancellation/cleanup, never synchronous native
`cancel()` inside a Swift `onCancel` handler.

## Verification and compatibility

Evidence root: `/Users/blaze/livekit/research-v3/swift-native-next/`.
The external `production-check` manifest symlinks all production source and the
selected repository tests. Support fixtures are original and unchanged, including
shared-key E2EE and remote statistics (`c6-fixture-provenance.txt`). No stand-ins.
Obsolete internal-manager tests are not reconstructed or counted as passing.

Statistics checkpoint: `217d310a`, artifact24723b41. Commands:

```sh
LIVEKIT_TESTING_URL=ws://127.0.0.1:17891 swift test --jobs 2 --package-path /Users/blaze/livekit/research-v3/swift-native-next/production-check --filter 'NativeCompatibilityTests|NativeRoomTests|NativeRoomProtoTests|localParticipantIdentity|remoteParticipants'
LIVEKIT_TESTING_URL=ws://127.0.0.1:17891 swift test --jobs 2 --package-path /Users/blaze/livekit/research-v3/swift-native-next/production-check --filter 'NativeCompatibilityTests|serverPermissionErrorKeepsTypedCause|NativeRoomProtoTests|PublishDataTests|DataTrackApiTests'
# In production-check:
LIVEKIT_TESTING_URL=ws://127.0.0.1:17891 TEST_RUNNER_LIVEKIT_TESTING_URL=ws://127.0.0.1:17891 xcodebuild test -scheme LiveKit -destination 'platform=macOS' -jobs 2 -only-testing:LiveKitObjCTests -derivedDataPath /Users/blaze/livekit/research-v3/swift-native-next/objc-dd -resultBundlePath /Users/blaze/livekit/research-v3/swift-native-next/objc-stats.xcresult
# In the owned Swift worktree:
JOBS=2 CACHE=/Users/blaze/livekit/research-v3/swift-native-next/api-cache .github/api-check/api-dump.sh /Users/blaze/livekit/research-v3/swift-native-next/api-stats-final macOS
.github/api-check/api-dump.sh --diff /Users/blaze/livekit/research-v3/swift-baseline/macOS /Users/blaze/livekit/research-v3/swift-native-next/api-stats-final/macOS
```

- `stats-regression.log`: 13 executed test functions / 14 cases pass; one camera
  function skipped. Files: NativeRoomTests.swift, NativeMediaTests.swift,
  NativeCompatibilityTests.swift, NativeRoomProtoTests.swift, ParticipantTests.swift
  (identity/membership). Covers native encrypted synthetic/physical audio,
  buffer video/VideoView, positive media statistics, streams/RPC, lifecycle/rejoin,
  observation/callback ordering, errors/deadline/cancel and release.
- `stats-compat-test.log`: 13 functions / 13 cases pass. Files: NativeCompatibilityTests,
  NativeRoomTests (permission case), NativeRoomProtoTests, PublishDataTests,
  DataTrack/DataTrackApiTests. Original data suites unchanged.
- `api-stats-final/macOS` at217d310a: Release/distribution build passes; saved
  digester reports zero breaking changes/additions. ObjC header hash remains
  `6819645bdc9f8c4b829736946aa1cc2321eb037dead76697855396b7559a0bdc`,
  with only unchanged category relocation versus baseline.
- `objc-stats.log` / `objc-stats.xcresult`: all21 original Objective-C methods/cases
  pass at217d310a, all seven files in Tests/LiveKitObjCTests unchanged.
- `stats-lint.log`: `swiftlint lint --strict` passes the exact18-file list in
  `stats-swift-files.txt`. Commit hook formats touched source.

Baseline Swift2fcaec9c/v2.20.0 dumps remain read-only at
`/Users/blaze/livekit/research-v3/swift-baseline`. No full baseline rerun or iOS runtime claim. Device API comparison now passes
with exact247 Apple slices (see finishing evidence). `media-camera-final.log` and `media-camera-builtin.log` retain
real camera capture timeouts; no camera images retained. Historical plaintext
proof logs are superseded for default fixtures; earlier unreliable burst-send
failure in `production-tests-7.log` remains unresolved. PCM decode is not speaker proof.

Cancellation baseline limitation: shipped FFI0.13.4 reader cancellation reproduces
the same two continuation-storage TSan signatures (120 cancellations); matched
120 reads without task cancellation report none. This is not migration-specific
and does not establish safety/fix. Deferred cleanup remains. Evidence:
`/Users/blaze/livekit/research-v3/current-cancellation/baseline/REPORT.md`.
Independent Claude review remains pending; this checkpoint is not acceptance.


Bounded finishing evidence (`finishing/` under the evidence root), source96cddfb0:

| Gate | Exact result / limitation |
|---|---|
| Camera baseline comparison | Same public `CameraProbe.swift`, linked to cached baseline2fcaec9c source tree `6ece42a33e33298d7447ba0f5fb7b7af0a35f0ec` and current217d310a. Commands `./baseline-camera`, then `./native-camera`, each capped25s. Both authorization3, MacBook Pro Camera ID `6C707041-05AC-0010-0008-000000000001`, not in use, session running, **no dimensions after10s**. Both processes exit0; this is failed capture evidence, not passing camera tests. Capturer source unchanged. No migration-specific adapter defect or OS/hardware root cause established. Build commands/module hashes/logs retained. |
| Automatic playout | Exact247 requires a microphone-owned PlatformAudio to enable shared platform output. `session/media.rs:259`, core `platform_audio/mod.rs:479`, `adm_proxy.cpp:85` and default-false flag explain the receive-only gap. This historical247 gap is fixed in b3bf27bb by session-owned leases; no Swift graph/fake mic. Existing core active/initialized diagnostics remain nonpublic. |
| Hardware callback proof | `lldb --batch -s output-after-subscribe.lldb native-audio` on saved `AudioProbe.swift`: remote audio tracks=1, then native `AudioDeviceMac::implDeviceIOProc` on CoreAudio `HALC_ProxyIOContext::IOWorkLoop`, nonnull outputData. Public setMicrophone enabled shared ADM. `output-after-subscribe-fixed.log` proves microphone-assisted hardware callback execution, **not receive-only activation, nonzero output samples or audible output**. Initial missed Swift marker retained as harness failure. No audio payloads recorded. |
| Two WebRTC binaries | Actual product test executable links LiveKitWebRTC and RustLiveKitFFI (`linked-libraries.txt`). LiveKitWebRTC universal30,189,824 bytes / arm64 slice13,412,608; RustLiveKitFFI arm64 debug106,313,632 includes native WebRTC symbols. Artifact sizes, not distribution-overhead estimates; exact hashes in `binary-provenance.txt`. Swift camera/frame/pixel/render utilities remain. `RTC.createVideoSource` initializes the old factory/ADM despite no Swift peer/signaling; avoidable future capture work, not a single-WebRTC claim. |
| Apple compile/API | All3 exact247 framework hashes verified (`apple-verified-hashes.txt`). Production iOS device Release/distribution build passes; `api-apple-final/iOS` has zero breaking changes/additions, ObjC header line multiset equal to baseline. Actual compiler target arm64-apple-ios15.0, device LC minimum13 (WebRTC members14; not iOS13 compatible). Arm64 simulator Release BUILD SUCCEEDED (`simulator-confirm.log`), native minimum14. Initial quiet build returned0 with spurious SwiftCompile failure text; one incremental confirmation passed. No device/simulator runtime or lower-OS proof. |
| Regression after package pin | `apple-regression.log`: **3 functions / 3 cases pass**, unchanged ParticipantTests.localParticipantIdentity/remoteParticipants and NativeRoomTests.productionRoomLifecycle. Original shared-key/statistics-enabled fixtures retained. |

Exact finishing build/test commands (all production Sources and generated FFI modules compiled):

```sh
JOBS=2 CACHE=/Users/blaze/livekit/research-v3/swift-native-next/api-cache .github/api-check/api-dump.sh /Users/blaze/livekit/research-v3/swift-native-next/api-apple-final iOS
.github/api-check/api-dump.sh --diff /Users/blaze/livekit/research-v3/swift-baseline/iOS /Users/blaze/livekit/research-v3/swift-native-next/api-apple-final/iOS
xcodebuild build -scheme LiveKit -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath /Users/blaze/livekit/research-v3/swift-native-next/api-cache/dd-iOS-Simulator -clonedSourcePackagesDirPath /Users/blaze/livekit/research-v3/swift-native-next/api-cache/spm -jobs 2 ARCHS=arm64 BUILD_LIBRARY_FOR_DISTRIBUTION=YES
LIVEKIT_TESTING_URL=ws://127.0.0.1:17891 swift test --jobs 2 --package-path /Users/blaze/livekit/research-v3/swift-native-next/production-check --filter 'localParticipantIdentity|remoteParticipants|productionRoomLifecycle'
```


Receive-only checkpoint626eecdf (`playout/` evidence): all3 framework hashes
verified; all3 generated Swift files byte-identical to247. Native owner evidence
`rust-ffi/room-apis-b3bf27bb/README.md` / `logs/playout-06-lldb-samples.log`:
two encrypted receive-only sessions, no microphones/decoded sinks; CoreAudio
returned1920 float32 samples,1916 nonzero (peak0.004974), then1918 nonzero
(peak0.004944) after one receiver closes. Recording stayed uninitialized.
Only aggregate metrics recorded; not audible, routing/volume or iOS runtime proof.
Acquisition failure logs and preserves subscription/decoding; those alone still
cannot guarantee output. Session teardown releases only its shared lease.
No Swift source/default API changes or native rebuild in this integration.

Swift regression `playout/regression.log`: **4 functions / 5 cases pass**
(NativeMediaTests.encryptedNativeAudioPublication, both parameter cases;
ParticipantTests.localParticipantIdentity/remoteParticipants;
NativeRoomTests.releasingConnectedRoomReleasesNativeDriver).
All package SHA256SUMS pass (`playout/all-hashes.log`). Fresh macOS Release/API
at626eecdf (`api-playout-final/macOS`): zero breaking/additions; public interface
and ObjC header byte-identical to217d310a. Prior247 iOS production build/API
proof remains scoped to that artifact; current native owner's per-slice Swift
compile/link checks and identical bindings establish packaging, not iOS runtime.

```sh
LIVEKIT_TESTING_URL=ws://127.0.0.1:17891 swift test --jobs 2 --package-path /Users/blaze/livekit/research-v3/swift-native-next/production-check --filter 'encryptedNativeAudioPublication|localParticipantIdentity|remoteParticipants|releasingConnectedRoomReleasesNativeDriver'
JOBS=2 CACHE=/Users/blaze/livekit/research-v3/swift-native-next/api-cache .github/api-check/api-dump.sh /Users/blaze/livekit/research-v3/swift-native-next/api-playout-final macOS
.github/api-check/api-dump.sh --diff /Users/blaze/livekit/research-v3/swift-baseline/macOS /Users/blaze/livekit/research-v3/swift-native-next/api-playout-final/macOS
```


Claude review corrections (on top of privacy note1ab66a54): legacy and modern
configured encryption `true` is idempotent; unsupported `false` rejection is
limited to outgoing payloads. Shared-key set/export/ratchet ignore participant ID.
RPC handlers are reserved before suspension and reconciled serially only after
native connect; concurrent duplicate/unregister cannot double-register. All17
native disconnect reasons map directly through existing proto/LiveKitError.
Native publishData/unpublish/mute/enable/subscription/settings errors are mapped.
Failed media attachment clears/cancels the partial track; metadata/quality/speaker
events no longer enumerate native media handles. Initial media attachment follows
the connected-state update. Dead Swift signaling sends/local factory observer were
removed; no replacement engine added.
Data-only regression (`review-fixes/data-final.log`): six functions/seven cases,
NativeReviewTests.swift and NativeCompatibilityTests.swift, exact command:

```sh
LIVEKIT_TESTING_URL=ws://127.0.0.1:17891 swift test --jobs 2 --package-path /Users/blaze/livekit/research-v3/swift-native-next/production-check --filter 'configuredEncryptionEnableIsIdempotent|rpcRegistrationDuringConnectAndConcurrentChanges|serverRemovalPreservesDisconnectReason|NativeCompatibilityTests'
```

Media/ObjC/API follow-up awaits the safe native replacement; no media run on b3
following the privacy finding. The review corrections require independent
re-review; old API dumps are not yet evidence for this source diff.

Prepared initial-subscription ordering assertion in NativeMediaTests.swift:
`swift test --jobs 2 --package-path /Users/blaze/livekit/research-v3/swift-native-next/production-check list`
builds/lists successfully (`review-fixes/test-build-list.log`); strict lint passes.
This is **compile-only**, not a media test pass; execution awaits the safe artifact.
