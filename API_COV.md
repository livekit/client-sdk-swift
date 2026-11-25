# Swift API coverage over the native room backend

**Review update:** independent reviews approve Rust `6bda549` and Swift
`a7913381` within the tested scope. Automatic microphone activation on receive
is removed. Safe receive-only speaker output remains a core-API gap.
An explicitly created microphone anywhere in the process can still mix physical
input into later PCM tracks, including tracks in other rooms. This core limitation
prevents claiming isolated PCM input. The reviewed macOS privacy guard covers
receive-first followed by PCM without an explicit microphone, not all capture paths.

Checkpoint: production Room integration against Rust
`08da67f24b3c46219320f29d3415e1114a80e9dc` (safe `6bda549` plus DTMF, subscription
permission and video quality controls; packaging-only head `d03e2063`).
Package: a local `livekit-ffi-xcframework` build of that revision (see "Local build"),
archive SHA-256 `c9b559931a7a22255710ff3490f4329a77bfcb363f1dc4cfcd8beae4139699ce`.
Verified macOS arm64 binary SHA-256:
`bc6c8fef9fa3b6c6811ef0515051309437ba3766ec6e1f8ceb2c04a90a3f779b`.
Do not mix 6bda bindings or slices with this package: four room checksums changed.
Automatic PlatformAudio activation is removed; safe receive-only output remains
blocked on a capture-independent public core API. Matching device/simulator slices require iOS14 and the package manifest requires
macOS11. SDK declarations iOS13/macOS10.15 therefore remain incompatible: **these are
minor-release blockers**, not established support. No stand-ins or second Room engine.

**Conclusion:** production encrypted connection, microphone/synthetic PCM,
buffer-video capture and remote `VideoView` rendering work through Rust.
Original unchanged shared-key/statistics-enabled participant fixtures now pass.
**Drop-in/minor-version compatibility remains unestablished.** Camera capture
times out on both baseline and migration. The b3 receive-only output proof is
not accepted after the microphone-activation privacy finding above; safe output
needs a core API. Audible output and iOS runtime remain unverified.
Complete metadata/errors/options and the full Apple target matrix remain gaps.
Independent reviews passed for the frozen revisions above. The parent reran the
exact Rust snapshot with both pinned submodules: 52 room-API tests passed
(10 live tests ignored), and all 34 legacy core-modules tests passed.

`implemented` means working-backend/PoC behavior exercised by the evidence below,
not minor-version compatibility; `pending` means
native support still needs Swift integration/verification; `compile-only` means
the public declaration remains without equivalent native behavior; `blocked`
means the required native/core access is absent. Throwing unsupported activation
fails with LiveKitError; nonthrowing APIs cannot provide that failure contract.

## Local build

TODO: When a `livekit-ffi-xcframework` release ships the room API, replace the local
package in `Package.swift` with that release.

No published LiveKitFFI package has the room API. `Package.swift` reads the package
from `../livekit-ffi-xcframework`, a directory next to this checkout. To use a
different directory, set the environment variable `LIVEKIT_FFI_PACKAGE_PATH` to its path.

To build the macOS package, you need Rust, Xcode and `tera` (`cargo install tera-cli`).

1. Get the Rust branch from https://github.com/livekit/rust-sdks/pull/1739 with its submodules.
2. In the Rust checkout, build the host library:
   `cargo build -p livekit-ffi --no-default-features --features room-apis,rustls-tls-webpki-roots`
3. Assemble the package. The script deletes the output directory first:
   `sh livekit-ffi/support/swift/package-room-macos.sh . target/debug/liblivekit_ffi.dylib <output directory>`
4. Move the output directory to `../livekit-ffi-xcframework`, or set `LIVEKIT_FFI_PACKAGE_PATH`.
5. In this checkout, build the SDK:
   `xcodebuild build -scheme LiveKit -destination 'platform=macOS'`

This package has only the macOS arm64 slice. For the iOS slices, see
`build-room-ios.sh` and `package-room-apple.sh` in `livekit-ffi/README.md` of the Rust branch.

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
| `Room.remoteParticipants`, `localParticipant`, metadata/state getters and delegates | **implemented** for room and participant state. Native records feed existing entity setters and StateSync directly (no Swift protobuf layer); identity retains the same RemoteParticipant across updates. | Two-room membership, name/metadata/attributes updates, departure and rejoin. Media publication records are projected; native audio/video Track handles attach to the same publications. |
| `LocalParticipant.publish(data:options:) async throws` | **implemented** payload delivery, `NativeRoomSession.publishData(payload:options:)`; encryption metadata remains incorrect/incomplete in the legacy callback. | Existing `PublishDataTests`: both permission cases, 100 reliable topics each. Native data-channel buffer-status callbacks are not exported. Core drops packet encryption type: legacy callback still receives `.none`, which is **not authoritative** for encrypted payloads (one warning per connection). No `.gcm` inference or metadata-parity claim. |
| `LocalParticipant.set(name:)`, `set(metadata:)`, `set(attributes:)` | **implemented**, native typed commands. | Production two-room update/identity test. |
| `sendText`, `sendBytes`, `sendFile`, `streamText`, `streamBytes`; byte/text reader/writer APIs | Native handles and room commands **available**; plaintext text/bytes/file/incremental variants **implemented** in production. Progress-specific Swift acceptance remains pending. | `NativeRoomTests` text and byte round trips; existing DataStreamObjCTests proves file, text and incremental byte/text writers. Native milestone README also proves all five commands. No old packet managers. |
| Internal `DataStreams.registerTextStreamHandler(for:ordered:_:) throws` used by ordered chat/transcription consumers | **blocked**: c6 provides independent `waitClosed()` but not causal close/open order. Baseline overlapping streams must remain concurrent; all-stream serialization breaks that contract. | Core `room/mod.rs:2497` ignores `OutputEvent::StreamClosed`; requires ordered `RoomEvent::StreamClosed(id,identity)`. Independently scheduled completion tasks cannot establish wire ordering. Public unordered handlers work. |
| `LocalParticipant.publishDataTrack(name:options:)`, `defineSchema(_:definition:)`, `getSchema(_:publishedBy:)`; data-track handles | **implemented**, native room commands and existing generated handle shapes. | Existing DataTrackApiTests, schema round-trip/missing-schema tests, timestamp/resubscribe/published-state tests. Buffering, frames and unpublish use Rust directly. |
| `LocalDataTrack.send(contentsOf:) async throws` | Real native `tryPush` path; **not fully verified** under burst loss. | Broader run failed the existing minimum-received-frame assertion; no reliability guarantee added to this unreliable transport. Paced/reassembly tests passed. |
| `Room.registerRpcMethod`, `unregisterRpcMethod`, `isRpcMethodRegistered`; `LocalParticipant.performRpc(...)` | Native RPC operations **available**, production echo/rejoin **implemented**. Native reply handles preserve errors; Swift handler tasks cancel on disconnect. | Production echo/rejoin plus custom code/message/data, unsupported method, response deadline, cancellation and subsequent-call tests pass. Pending-reply disconnect remains pending. |
| `Participant.capabilities: [ClientCapability]`, `clientProtocol` | Remote capabilities now mapped; local capabilities **compile-only** because native local snapshot is nil. Nondefault connect clientProtocol rejects: public core RoomOptions cannot override SignalOptions; the new export accepts only nil/default2. | No longer a missing remote-field/helper blocker. Core negotiates native sends. |
| Token/log helpers (`Claims`, `TokenOptions`, inference/observability grants, `logForwardBootstrap`, `logForwardReceive`) | **available**, compatible generated 0.13.4 shapes; production compiles without replacement types. | Real token generation exercised by all integration fixtures. Old missing-export claims resolved. |
| Media publish/subscribe and `TrackPublication.track` | **implemented working path**: native source/publication handles attach to existing NSObject tracks; remote PCM/video sinks feed AudioRenderer/VideoView; mute/unmute/unpublish/unsubscribe route native. | Swift encrypted synthetic PCM + physical microphone + buffer video/VideoView pass, including initial publication snapshot and identity across mute. Camera capture times out identically on unchanged baseline and migration with the same built-in device/authorization; no migration-specific adapter defect established. The b3 automatic PlatformAudio lease is rejected after the privacy review: its tested event order did not establish general capture safety. Safe receive-only output needs a core API; no audible-output claim. An explicit microphone anywhere in the process can mix physical input into later PCM tracks across rooms; isolated PCM input is not established. Custom encoding/processing options reject pending mappings. |
| `RemoteTrackPublication.set(preferredFPS:)`, `RemoteAudioTrack.volume` | FPS control and per-track volume **blocked** on core/export support; volume is nonthrowing and **compile-only** for native media. | Requires actual controls, not fake setters. |
| `AudioManager.setManualRenderingMode(_:)`, graph observers/mixer/custom-processing delegates | AVAudioEngine graph access **blocked** while Rust owns the device; manual-rendering activation throws. Nonthrowing graph interfaces are **compile-only**. | Exposing/owning the real graph would require a separate audio-device design; no large adapter added. |
| `AudioManager.setPlatformVoiceProcessingAllowed(_:)`, `LocalAudioTrack.setAudioProcessingOptions(_:)`, voice processing/AGC controls | **pending mapping**, not inherently impossible. Current throwing activation rejects because this artifact supplies no native mapping. Nonthrowing controls are **compile-only** for native media. | Distinguish core-supported processing controls from graph-access blockers; validate the actual next media exports before wiring. |
| Room encryption options / `setE2EEEnabled(_:)` | **implemented shared-key index-zero configuration**: BaseKeyProvider retains the actual native provider across the session, forwards key updates/export/ratchet; Room connects with native data+media or legacy media-only encryption. Callbacks remain incomplete. | Core `RoomEvent::DataReceived` at `room/mod.rs:207` drops per-packet encryption despite `handle_data` receiving it at 1846–1874. Core `E2eeStateChanged` at :252 lacks track SID (`e2ee/manager.rs:204–210` discards it). Require per-packet encryption and track-associated events upstream; cannot infer from mutable participant/config or fan out a guessed publication. Independent current-key-index/media-data dynamic-toggle parity absent. Unsupported nonthrowing switches log/reject activation rather than claim a native change; these are compatibility breaks. Per-participant/multi-index custom-provider parity is unproved. |
| `RoomOptions.reportRemoteTrackStatistics`, `Track.statistics` | **implemented** native publication `getStatistics()` polling through existing TrackStatistics models and previous samples. | Encrypted audio/video produce positive sent/received counters; UInt64 above 2^53, id/codecId/SSRC verified. Protobuf default values cannot restore original absent-field optionality. Full sample/default/backup-codec parity remains unproved. |
| `Room.serverVersion`, `serverRegion`, `serverNodeId` | **compile-only**, nil: native snapshots omit server info. | Needs native/core metadata access. |
| `Room.connect`/stream command error types | **implemented typed mapping** for native Signal HTTP source/status/timeout, RequestFailure, RTC and stream IO/cancellation/state variants. | Exact typed permission rejection tested against server, misleading reason strings tested locally. Older reason-only cases and core-erased transport/region causes remain parity gaps; no string parsing. Other public command boundaries still need complete error audit. |
| `Room.prepareConnection(url:token:)` | **implemented reduced**: state/URL validation and HTTP prewarm retained; the Swift region fetch was removed because connect never read it. Region errors are no longer reported here. | The native session resolves the Cloud region during connect. |
| `Room.debug_simulate(scenario:)` | Unsupported activation throws. | No native simulation command exported. |
| Client metrics (`.metrics` data packets for published/subscribed tracks) | **not sent**: the Swift MetricsManager was removed, because `Room.send` rejects every non-user packet and each send failed. `Track.statistics` callbacks are unaffected. | Needs a native metrics export; no Swift mapping added. |
| `room(_:didStartReconnectWithMode:)`, `didCompleteReconnectWithMode:`, `didUpdateReconnectMode:` | **not emitted**: the native session does not report a reconnect mode. `didUpdateConnectionState`, `roomIsReconnecting` and `roomDidReconnect` remain. The false `reconnectMode should not be .none` error log on native reconnect is removed. | Needs a native reconnect-mode event. |
| iOS, Catalyst, tvOS, visionOS | Matching safe package includes macOS and arm64 iOS device/simulator. Production device Release/API and arm64 simulator Release compilation pass at3d4754e1. Catalyst/tvOS/visionOS and Intel simulator slices absent. | No iOS runtime claim. Both WebRTC archives have2946 minimum-version commands, all14: device LC13 does NOT establish iOS13 support. SDK declaration13 is a real compatibility blocker. |

Review-specific remaining gaps (existing declarations retained):

| Signature / callback | Status |
|---|---|
| `LocalParticipant.publishDtmf(code:digit:) async throws` | **implemented, send only**: native `publishDtmf` with no destinations (broadcast, as baseline). Core sends it reliably without data E2EE, so no encrypted-payload guard; an encrypted-room send passes. No public Swift DTMF receive callback exists; native `dtmfReceived` is ignored, and receipt is not verified. |
| `LocalParticipant.setTrackSubscriptionPermissions(allParticipantsAllowed:trackPermissions:) async throws` | **implemented**: native identity-based command. Each SID resolves to a current remote identity; unknown SIDs are skipped as the server does, but so is a participant this client has not seen yet. Precedence is kept: allParticipantsAllowed sends no entries, allTracksAllowed sends no track SIDs, so ignored invalid SIDs do not throw; an applied invalid SID rejects. Completion is desired state, not server acknowledgement; core resends on reconnect. Revocation can leave a stale status or track; native permission status is not projected to `isSubscriptionAllowed`. Deny is only observed as no track within 1s; server log shows the denied and allowed updates. |
| `RemoteTrackPublication.set(videoQuality:) async throws` | **implemented as a request**: native `setVideoQuality` for video only; audio stores the setting only, as the server ignores it. Track settings send only the changed native commands, and a failed request keeps the previous local value. Success means the core accepted the request, not that the SFU selected the layer; core ignores non-simulcast tracks. Preferred FPS still rejects. |
| `Room.connect(...)` on an already-connected Room | Throws invalidState rather than baseline reconnect behavior; compatibility unresolved. |
| `room(_:participant:trackPublication:didReceiveTranscriptionSegments:)`, `room(_:didFailToDecryptDataWithEror:)` | No corresponding native delivery mapping; exact native transcription/decryption events needed. No fabricated callbacks. |
| Per-publication encryption-state callbacks | Native participant/state event lacks track SID; cannot associate truthfully. `E2EEManager` keeps its public API but creates no Swift frame cryptors; its RoomDelegate conformance methods and `enableE2EE(enabled:)` affect only its own flag. |
| `DataTrackPublishTests.encryptionToggleAfterConnectApplies` | **Known incompatible, not passed**: calls `setE2EEEnabled(false)` before data-track publication. Dynamic disable remains unsupported; outgoing payload activation rejects. Metadata/name/attributes and legacy plaintext data/streams/RPC are unaffected. |

## SwiftPM module inventory (b0291abc -> prune)

Removed targets: `CLiveKitProto`, `LiveKitNanopb`, `LiveKitNanopbTests`; removed package
dependency: swift-protobuf (test-only); removed submodule: `protocol`. Remaining:
`LiveKit` (depends on `LKObjCHelpers`, LiveKitWebRTC, LiveKitFFI), `LKObjCHelpers`,
`LiveKitTestSupport` and the Core/Audio/ObjC test targets. LiveKitWebRTC stays for local
capture, render and the audio device module; `LKObjCHelpers` stays because public
`LKSampleHandler` calls its broadcast-finish helper. Source: `swift package describe` on both trees.

## Prune gates (evidence in research-v3/swift-prune)

Gate head 681232eb for compile, broad runtime, ObjC, API and lint; the test follow-up head
changes only Tests, test support and this file (production Sources identical).

| Gate | Result |
|---|---|
| Full SwiftPM test-target compile | `swift build --build-tests --jobs 2` in a fresh scratch: exit 0, Core/Audio/ObjC bundles built, no protocol targets. Compilation proof, not a runtime pass. |
| Broad runtime, owned server (681232eb, red log kept in `freeze-3a182106/gates/final-runtime.log`) | **Not green.** 118 tests in 17 suites, 71 issues. Named terminal records: 109 pass, 8 fail. 39 of the issues are `encryptionType != .none` callback expectations recorded unattributed (`«unknown»`), so they occur even while the named encryption tests report a pass. The 8 failures and other issues are nondefault clientProtocol (17), decrypt-failure callback (4), nonzero key index (2), `debug_simulate` (2), and 7 follow-on missed receipts. These causes are established from the pre-prune source paths, not from a paired pre-prune run of all 71 issues. |
| Prior compatibility gate (22 functions / 32 cases) | All pass at the follow-up head. Participant protocol/capability constructors moved to native records; the unknown raw capability argument became `.unused` because the native enum is finite, so not every argument is identical. |
| Restored public coverage (follow-up head) | Attachments IDs/order/content/topic, missing-file failure, cancelled multi-file send (cancelled when the receiver sees an attachment byte stream open, with the send asserted still pending; large incompressible files keep it in flight; a first-chunk trigger was rejected because the send had already returned), peer-advertised capabilities, room default audio options on native publish, open reader failing on disconnect, unknown-sender mapping: pass. Server-stamped attribution passes for sender identity in plaintext and encrypted rooms; the encrypted `.gcm` expectation stays as a known failing regression. A forged inner identity cannot reach Swift through the public API, so its precedence is not proven here. |
| Setup retry | Every attempt validates every room's identity and connects only unconnected rooms; `TestEnvironmentTests` covers the former masking case. |
| Unchanged ObjC suite (681232eb) | 21/21 pass. |
| API digester, macOS and iOS device Release (681232eb) | Against 2fcaec9c and b0291abc: 0 breaking, 0 additions. ObjC header declarations are an equal multiset; text differs only in doc comments and the moved `Room` prepareConnection category. Selftest passes. |
| iOS simulator Release, lint (681232eb) | Builds; SwiftLint 0 warnings, SwiftFormat clean. |

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
and remove the handler. Independent review approved the manager-options and Apple-package follow-ups.

| Gate | Evidence and scope |
|---|---|
| Focused safe runtime | `review-followup/focused.log`: **8 functions / 10 cases pass**. Files NativeReviewTests.swift, NativeCompatibilityTests.swift, NativeMediaTests.swift. Covers legacy/modern encryption and shared keys, connecting/concurrent/residual RPC registration, typed permission/removal errors, encrypted synthetic/physical audio, video/VideoView, statistics and connected-before-subscribe ordering. No b3 media run after the privacy finding. |
| Public API | `api-manager-final/macOS` at23dfa1f7: Release/distribution passes; both breaking and reversed-addition reports inspected, no changes. Swift interface and ObjC header byte-identical to626eecdf. `--diff` exit0 alone is not a compatibility gate. Matching-safe iOS recheck at3d4754e1 reports zero changes/additions; header only relocates unchanged prepareConnection category (identical line multiset). |
| Objective-C | `review-followup/objc.log` / `objc.xcresult`: all21 unchanged methods in all7 Tests/LiveKitObjCTests files pass on safe6bda549 / source0c2e35d2. |
| Lint | Strict lint passes changed source/test files (`review-followup/lint-final.log`, `test-lint.log`); source commit hook formats touched files. |
| Original defaults | Earlier original Participant identity/membership, PublishDataTests and DataTrackApiTests passed with unchanged shared-key/statistics-enabled support fixtures (`c6-fixture-provenance.txt`, `stats-regression.log`, `stats-compat-test.log`). No weakened fixture counted as default parity. |
| Camera | `finishing/CameraProbe.swift` linked against baseline2fcaec9c and current-at-test217d310a; both same authorization3/deviceID `6C707041-05AC-0010-0008-000000000001`, not in use, session running, **no dimensions after10s**. Process exit0 is not capture success. `baseline-camera.log`/`native-camera.log`, module hashes and commands retained. No migration-specific adapter defect or OS/hardware cause established. |
| Two WebRTC binaries | Historical `finishing/linked-libraries.txt`/`binary-provenance.txt`: actual executable links LiveKitWebRTC (universal30,189,824 bytes / arm64 slice13,412,608) and RustLiveKitFFI (247 arm64 debug106,313,632 bytes, bundled WebRTC). Artifact sizes, not distribution-overhead estimates. Swift camera/frame/pixel/render utilities and old factory/ADM initialization via createVideoSource remain; no Swift peer/signaling is constructed. Single-WebRTC investigation remains read-only. |
| Output safety | Historical b3 nonzero CoreAudio-buffer proof is withdrawn as general privacy evidence; it only covered publish-before-lease order. Safe6bda549 removes automatic lease activation. Native owner's receive-first then same/other-session PCM regression records0 acquisition/recording breakpoint hits (`room-apis-6bda549-safe/README.md`). Safe independent receive-only speaker output remains blocked. An explicit microphone in any room can mix physical input into later PCM tracks process-wide. Only the guarded LLDB run checks acquisition/recording; a plain test pass does not prove their absence. No audible-output or iOS capture-safety claim. |

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
iOS14 native minimum remains a minor-compatibility blocker. At 08da67f all three
framework slices pass strict `codesign --verify --deep --strict`: the earlier macOS
“ambiguous bundle format” came from copies that flattened versioned symlinks. They are
ad-hoc debug signatures, with no release or notarization claim. Both Rust reviewers approved the frozen6bda549 scope; the Swift packaging/API review approveda7913381.
Parent recovery log `manager-options/parent-recovery-tests.log` passes2functions/5cases;
parent verified and stopped owned server85789 after the run.

Apple gate commands (system toolchain, no native rebuild):
```sh
PATH=/usr/bin:/bin:$PATH JOBS=2 CACHE=/Users/blaze/livekit/research-v3/swift-native-next/api-cache .github/api-check/api-dump.sh /Users/blaze/livekit/research-v3/swift-native-next/api-safe-apple iOS
PATH=/usr/bin:/bin:$PATH .github/api-check/api-dump.sh --diff /Users/blaze/livekit/research-v3/swift-baseline/iOS /Users/blaze/livekit/research-v3/swift-native-next/api-safe-apple/iOS
```
Exact simulator/device xcodebuild commands and hashes are saved with the final
review packet; only production build targets run, no runtime test cases.

## Controls 08da67f (Swift `b23c1e07`)

Evidence: `/Users/blaze/livekit/research-v3/swift-native-next/controls-08da67f/`.
Owned server127.0.0.1:17941 (rtc tcp17944/udp17945), stopped after the run; at most2 jobs.
External check package is a copy of production-check with symlinks to this worktree.

| Gate | Result |
|---|---|
| New controls | `NativeControlsTests.swift`: **2 functions / 2 cases pass**. The permission test fails with “invalid allowed track SID” when the allTracksAllowed fix is reverted. The closed-session quality failure also passes on old code, so it covers state preservation, not the removed setEnabled call. |
| Regressions | 20 unchanged functions in NativeRoomTests (5), NativeReviewTests (4), NativeCompatibilityTests (6 in the suite), encryptedBufferVideoRenders, PublishDataTests (2), ParticipantTests (2). With the new tests: **22 functions / 32 cases pass**. No microphone, camera or capture test ran. |
| Objective-C | All **21** methods pass (`xcodebuild ... -only-testing:LiveKitObjCTests`). |
| Public API | macOS and iOS: zero breaking, zero additions. The Swift interface differs from the approved checkpoint only in doc notes and the package name. ObjC headers add only doc lines; non-doc line multiset equals baseline. |
| Apple builds | iOS device and simulator Release `xcodebuild build` succeed. No iOS runtime claim. |
| Lint | Strict swiftlint and swiftformat pass all 6 changed Swift files. |

Native 08da67f review approved. Swift `b23c1e07` fixes both Codex blockers on `fc45878e` and awaits Codex re-review.
