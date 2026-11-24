# Swift API coverage over the native room backend

**Review update:** native artifact `b3bf27bb` is not accepted. Its automatic
playout lease can enable microphone capture when a PCM track is published later.
That activation is being removed. Safe receive-only speaker output remains a
core-API gap; the output measurements below cover only the tested event order,
not general capture safety. The Swift and Rust reviews are not yet complete.

Checkpoint: production Room integration against safe Rust
`6bda54970f8d24c845d5a1ef32bed6b8bf133c17` (shipped FFI0.13.4 baseline).
Package: `/Users/blaze/livekit/research-v3/rust-ffi/room-apis-6bda549-safe-apple/livekit-ffi-xcframework`.
Verified macOS arm64 binary SHA-256:
`ba4a237e1268adc8df39657f7559dbe007dae122afb64cc97c5e78647cabfde9`.
Automatic PlatformAudio activation is removed; safe receive-only output remains
blocked on a capture-independent public core API. Matching safe device/simulator slices are now available; both explicitly require
iOS14. SDK declaration13 therefore remains incompatible: **iOS13 is a
minor-release blocker**, not established support. No stand-ins or second Room engine.

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
| Public Swift/ObjC declarations, enum values, selectors, availability | macOS Release/distribution at `23dfa1f7` and matching-safe iOS device at `3d4754e1`: digester reports zero breaking changes and zero additions. ObjC header differs only by relocating the unchanged Room.prepareConnection category; exact header line multiset is equal. Enum/selector/availability text is unchanged. This is surface evidence, not behavioral compatibility. |
| Existing unmodified public E2E | 21 existing Objective-C test methods passed unchanged, including streams/file/incremental writers, data tracks, RPC and Room delegates. Current participant identity/membership, PublishDataTests and DataTrackApiTests also pass with original unchanged shared-key/statistics-enabled fixtures; this does not imply all default/media behavior is compatible. |
| Lifecycle/default/error/delegate/observation semantics | Two-room state/delegate/data/rejoin, invalid-token, cancellation and release proof exists. Sequential name callback ordering/getter consistency and SwiftUI notification delivery now pass. Involuntary reconnect, full error parity and default-option parity remain unproved. New unsupported throws and ineffective nonthrowing controls are **compatibility breaks**. |
| Supported build/package/target matrix | Current safe macOS arm64 Debug/Release pass. Matching-safe iOS device Release/API and arm64 simulator Release compilation pass; iOS14 native minimum remains incompatible with SDK declaration13. Catalyst/tvOS/visionOS/Intel simulator slices absent. Absolute local artifact pin is research packaging, not a distributable minor release. |

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
| iOS, Catalyst, tvOS, visionOS | Matching safe package includes macOS and arm64 iOS device/simulator. Production device Release/API and arm64 simulator Release compilation pass at3d4754e1. Catalyst/tvOS/visionOS and Intel simulator slices absent. | No iOS runtime claim. Both WebRTC archives have2946 minimum-version commands, all14: device LC13 does NOT establish iOS13 support. SDK declaration13 is a real compatibility blocker. |

Review-specific remaining gaps (existing declarations retained):

| Signature / callback | Status |
|---|---|
| `LocalParticipant.publishDtmf(code:digit:) async throws` | Unsupported native packet activation; needs the core-supported room DTMF export. |
| `LocalParticipant.setTrackSubscriptionPermissions(allParticipantsAllowed:trackPermissions:) async throws` | Unsupported activation; needs native room subscription-permission command. |
| `RemoteTrackPublication.set(videoQuality:) async throws` | Unsupported nondefault quality, separately from FPS; needs publication quality export. |
| `Room.connect(...)` on an already-connected Room | Throws invalidState rather than baseline reconnect behavior; compatibility unresolved. |
| `room(_:participant:trackPublication:didReceiveTranscriptionSegments:)`, internal `room(didReceiveTranscriptionPacket:)`, `room(_:didFailToDecryptDataWithEror:)` | No corresponding native delivery mapping; exact native transcription/decryption events needed. No fabricated callbacks. |
| Per-publication encryption-state callbacks | Native participant/state event lacks track SID; cannot associate truthfully. |
| `DataTrackPublishTests.encryptionToggleAfterConnectApplies` | **Known incompatible, not passed**: calls `setE2EEEnabled(false)` before data-track publication. Dynamic disable remains unsupported; outgoing payload activation rejects. Metadata/name/attributes and legacy plaintext data/streams/RPC are unaffected. |

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
Current source `23dfa1f7`, safe native6bda549. No native rebuild or speculative
additive exports consumed. Public declarations retained; no migration acceptance.

Claude approved008d5420 with no blockers and independently verified source/package
provenance, macOS API reports, ObjC21, focused8functions10cases and lint.
The approved corrections defer publication attachment until receive setup succeeds,
so failed setup cleanup cannot emit an unmatched unsubscribe. Connected precedes
initial subscribe. Legacy false-toggle leaves plaintext data/streams/RPC usable;
modern encrypted payloads and encrypted media/data-track activation still reject.
Unregister failure clears native confirmation only: an unregistered Swift handler
rejects residual invocations, and re-registering replaces the native core handler.
The real-native residual/replacement test passes; no healthy-session unregister
failure was injected. Rare pending-RPC registration failure can still fail connect
and remove the handler. The narrow manager-options delta below remains for final review.

| Gate | Evidence and scope |
|---|---|
| Focused safe runtime | `review-followup/focused.log`: **8 functions / 10 cases pass**. Files NativeReviewTests.swift, NativeCompatibilityTests.swift, NativeMediaTests.swift. Covers legacy/modern encryption and shared keys, connecting/concurrent/residual RPC registration, typed permission/removal errors, encrypted synthetic/physical audio, video/VideoView, statistics and connected-before-subscribe ordering. No b3 media run after the privacy finding. |
| Public API | `api-manager-final/macOS` at23dfa1f7: Release/distribution passes; both breaking and reversed-addition reports inspected, no changes. Swift interface and ObjC header byte-identical to626eecdf. `--diff` exit0 alone is not a compatibility gate. Matching-safe iOS recheck at3d4754e1 reports zero changes/additions; header only relocates unchanged prepareConnection category (identical line multiset). |
| Objective-C | `review-followup/objc.log` / `objc.xcresult`: all21 unchanged methods in all7 Tests/LiveKitObjCTests files pass on safe6bda549 / source0c2e35d2. |
| Lint | Strict lint passes changed source/test files (`review-followup/lint-final.log`, `test-lint.log`); source commit hook formats touched files. |
| Original defaults | Earlier original Participant identity/membership, PublishDataTests and DataTrackApiTests passed with unchanged shared-key/statistics-enabled support fixtures (`c6-fixture-provenance.txt`, `stats-regression.log`, `stats-compat-test.log`). No weakened fixture counted as default parity. |
| Camera | `finishing/CameraProbe.swift` linked against baseline2fcaec9c and current-at-test217d310a; both same authorization3/deviceID `6C707041-05AC-0010-0008-000000000001`, not in use, session running, **no dimensions after10s**. Process exit0 is not capture success. `baseline-camera.log`/`native-camera.log`, module hashes and commands retained. No migration-specific adapter defect or OS/hardware cause established. |
| Two WebRTC binaries | Historical `finishing/linked-libraries.txt`/`binary-provenance.txt`: actual executable links LiveKitWebRTC (universal30,189,824 bytes / arm64 slice13,412,608) and RustLiveKitFFI (247 arm64 debug106,313,632 bytes, bundled WebRTC). Artifact sizes, not distribution-overhead estimates. Swift camera/frame/pixel/render utilities and old factory/ADM initialization via createVideoSource remain; no Swift peer/signaling is constructed. Single-WebRTC investigation remains read-only. |
| Output safety | Historical b3 nonzero CoreAudio-buffer proof is withdrawn as general privacy evidence; it only covered publish-before-lease order. Safe6bda549 removes automatic lease activation. Native owner's receive-first then same/other-session PCM regression records0 acquisition/recording breakpoint hits (`room-apis-6bda549-safe/README.md`). Safe independent receive-only speaker output remains blocked. No audible-output claim. |

Current exact commands (owned server17891, at most2 jobs):

```sh
LIVEKIT_TESTING_URL=ws://127.0.0.1:17891 swift test --jobs 2 --package-path /Users/blaze/livekit/research-v3/swift-native-next/production-check --filter 'configuredEncryptionEnableIsIdempotent|rpcRegistrationDuringConnectAndConcurrentChanges|serverRemovalPreservesDisconnectReason|NativeCompatibilityTests|encryptedNativeAudioPublication|encryptedBufferVideoRenders'
JOBS=2 CACHE=/Users/blaze/livekit/research-v3/swift-native-next/api-cache .github/api-check/api-dump.sh /Users/blaze/livekit/research-v3/swift-native-next/api-review-safe macOS
.github/api-check/api-dump.sh --diff /Users/blaze/livekit/research-v3/swift-baseline/macOS /Users/blaze/livekit/research-v3/swift-native-next/api-review-safe/macOS
# In the external production-check package:
LIVEKIT_TESTING_URL=ws://127.0.0.1:17891 TEST_RUNNER_LIVEKIT_TESTING_URL=ws://127.0.0.1:17891 xcodebuild test -scheme LiveKit -destination 'platform=macOS' -jobs 2 -only-testing:LiveKitObjCTests -derivedDataPath /Users/blaze/livekit/research-v3/swift-native-next/objc-dd -resultBundlePath /Users/blaze/livekit/research-v3/swift-native-next/review-followup/objc.xcresult
```

The external manifest symlinks production source and selected unchanged public
tests; obsolete internal-manager tests are not reconstructed or counted as passing.
Baseline2fcaec9c/v2.20.0 dumps remain read-only in `research-v3/swift-baseline`.
No full baseline rerun; historical unreliable burst-send failure remains unresolved.

Cancellation baseline limitation: shipped FFI0.13.4 reader cancellation reproduces
the same two continuation-storage TSan signatures (120 cancellations); matched
120 reads without task cancellation report none. Not migration-specific, not a
safety/fix proof. Deferred cleanup remains. Evidence:
`/Users/blaze/livekit/research-v3/current-cancellation/baseline/REPORT.md`.

Narrow manager-options follow-up23dfa1f7: both toggle and operation guards use
`Room.State.roomOptions`, the immutable options selected/stored by NativeRoomDriver
at connect. Replacing or clearing public e2eeManager cannot change this decision.
Package blob remains identical to008d5420; no artifact/default/API redesign.
`manager-options/tests.log`: **2 functions / 5 cases pass** in NativeReviewTests.swift
(existing legacy/modern enable test plus plaintext/legacy/modern manager replacement,
nil and opposite constructor/connect-time options). Strict lint passes Room.swift
and NativeReviewTests.swift. Fresh macOS Release/API reports zero changes/additions;
Swift interface and ObjC header are byte-identical to the approved checkpoint.
No broad runtime rerun. Claude final re-review approvedaf45ccaf with no blockers.
Parent rerun recovered after selecting system Swift and restoring the owned server:
manager-options/recovery-tests.log records the same2functions/5cases passed.
Use `PATH=/usr/bin:/bin:$PATH` and start the configured server before these tests.

```sh
LIVEKIT_TESTING_URL=ws://127.0.0.1:17891 swift test --jobs 2 --package-path /Users/blaze/livekit/research-v3/swift-native-next/production-check --filter 'managerReplacementUsesConnectedEncryptionOptions|configuredEncryptionEnableIsIdempotent'
swiftlint lint --strict Sources/LiveKit/Core/Room.swift Tests/LiveKitCoreTests/NativeReviewTests.swift
JOBS=2 CACHE=/Users/blaze/livekit/research-v3/swift-native-next/api-cache .github/api-check/api-dump.sh /Users/blaze/livekit/research-v3/swift-native-next/api-manager-final macOS
.github/api-check/api-dump.sh --diff /Users/blaze/livekit/research-v3/swift-baseline/macOS /Users/blaze/livekit/research-v3/swift-native-next/api-manager-final/macOS
```

Matching-safe Apple pin3d4754e1 changes only Package.swift's local artifact path;
Sources are identical to approvedaf45ccaf. All SHA256SUMS entries and archive hash
`06b940bc0029d5bc7acec1f4a6b6adf79f4658cb6312c45b409e33bc3c1d5a2c` verified;
all3 generated Swift files and the macOS binary are unchanged. Evidence:
`safe-apple/` and `api-safe-apple/iOS`. Device/API reports zero breaking/addition
entries; ObjC header line multiset matches baseline. Device/simulator incremental
verification result bundles resolve initial Xcode “failed with exit code0” log
messages; both builds succeeded. No iOS runtime claim or Swift platform-floor edit.
iOS14 native minimum remains a minor-compatibility blocker. Native iOS signatures
verify; unchanged macOS bundle fails strict signature validation (“ambiguous bundle
format”), a research-packaging/distribution blocker. Native independent review pending.
Parent recovery log `manager-options/parent-recovery-tests.log` passes2functions/5cases;
parent verified and stopped owned server85789 after the run.

Apple gate commands (system toolchain, no native rebuild):
```sh
PATH=/usr/bin:/bin:$PATH JOBS=2 CACHE=/Users/blaze/livekit/research-v3/swift-native-next/api-cache .github/api-check/api-dump.sh /Users/blaze/livekit/research-v3/swift-native-next/api-safe-apple iOS
PATH=/usr/bin:/bin:$PATH .github/api-check/api-dump.sh --diff /Users/blaze/livekit/research-v3/swift-baseline/iOS /Users/blaze/livekit/research-v3/swift-native-next/api-safe-apple/iOS
```
Exact simulator/device xcodebuild commands and hashes are saved with the final
review packet; only production build targets run, no runtime test cases.
