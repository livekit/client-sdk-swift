# Changelog

## [2.19.0] - 2026-10-26

### Changed

- Register the SDK's own WebSocket/URLSession stack as livekit-net's transport, so Rust-side signalling and HTTP reuse the tuned session (call-signaling QoS, multipath handover, TLS workarounds) instead of a second parallel client; a rejected WebSocket upgrade now keeps its HTTP status
- The video start bitrate cap for camera tracks now scales with how long the connection took to set up: 1 Mbps up to 1.5 s, falling linearly to 300 kbps at 3.5 s and beyond. Screen share stays uncapped. Same behaviour as client-sdk-js, rust-sdks and client-sdk-android
- The Rust core dependency changed from LiveKitUniFFI to LiveKitFFI 0.13.1 for SwiftPM and CocoaPods. The SwiftPM dependency moved to livekit-ffi-xcframework, with the product LiveKitFFI and the binary target RustLiveKitFFI. SwiftPM re-resolves the package once. CocoaPods resolves the LiveKitFFI pod instead of LiveKitUniFFI
- Data streams: reimplemented on the Rust livekit-data-stream core over UniFFI, adding DEFLATE compression and single-packet inlining for one-shot sends when every recipient supports them, a configurable incoming payload cap via RoomOptions.dataStreamOptions, StreamTextOptions.operationType and generated, senderIdentity on both stream options, file attachments for a one-shot sendText, TextStreamInfo.mimeType, Participant.capabilities, and a StreamError case for each failure the core reports

### Fixed

- Update LiveKitWebRTC to 150.7871.04, which removes the AAA Certificate Services root from the TURN/TLS trust anchors so certificates from the compromised eMudhra intermediates are rejected
- Fix a crash (SIGSEGV in `pb_enc_varint`) on the first reliable data send in optimized CocoaPods builds: the encoder could read a message that was already freed
- performRpc throws CancellationError at once when the calling task is cancelled
- Fix a crash (SIGSEGV in `strlen` from `RegionManager`) when connecting to LiveKit Cloud in optimized builds: generated protobuf getters could read a message that was already freed
- Fix media frame cryptors ignoring the key provider's current key index; senders now follow `setKey(index:)` / `setCurrentKeyIndex` live. In non-shared key mode `setKey(key:participantId:index:)` no longer moves the current key index (it may be a remote participant's key); use `setCurrentKeyIndex` to switch the local one

## [2.18.0] - 2026-10-13

### Added

- Custom video encoder factories: call LiveKitSDK.set(videoEncoderFactory:) before any other SDK API with an implementation of the new VideoEncoderFactory and VideoEncoder protocols to supply H264 or H265 encoders in place of the default VideoToolbox backed ones, optionally with exclusive: true so VideoToolbox never encodes
- Screen sharing on iOS 27+ now captures in-process via ScreenCaptureKit, selecting content through the system picker with no Broadcast Upload Extension or app group. Enabling screen share waits for the user's selection and throws if they dismiss the picker, so no empty track is published, and stopping the share from system UI unpublishes the track. Set the new `ScreenShareCaptureOptions.useScreenCaptureKit` to `false` to keep the ReplayKit paths on iOS 27
- Enable WARP (SPED: DTLS handshake carried in the ICE exchange, SNAP: SCTP association parameters in SDP), shortening connection and data channel setup. Always on and negotiated with the server: a server without WARP support gets a standard handshake

### Changed

- Drop signal messages that arrive before the Join/ReconnectResponse, matching the Rust SDK, and log a warning naming each dropped message type
- In single peer connection mode the publisher offer is now created before the signal socket opens and bundled with the JOIN request, so the server answers it in the same exchange — removing a round trip from the connect path, which matters most on high-latency links
- Published video starts at 90% of its target bitrate (capped at 1 Mbps unless it is a screen share) instead of libwebrtc's ~300 kbps default, by declaring `x-google-start-bitrate` on the video codecs' fmtp in the publisher's offer. The hint is one connection-level value — the largest among the sending video tracks — written to every video section, and only on the first offer that carries local video, since libwebrtc applies it to the whole peer connection and retains it across network route changes. Same behaviour as client-sdk-js, rust-sdks and client-sdk-android

### Fixed

- Fix a failed full reconnect being reported as success: the room read `.connected` on a session the full reconnect had already cleaned up (no sid, no participants, no media) and never reconnected or disconnected; later attempts now retry the full reconnect, and when all fail the room disconnects with the error
- Audio transceivers are now stopped on unpublish, the same as video, so repeated publish/unpublish cycles no longer accumulate native transceiver memory for the lifetime of the connection
- Publishing a data track while a full reconnect was in progress could fail with a disconnected error, because the reconnect republished existing tracks after the new publish had already started; the publish now waits until the republish has been issued
- Fix a crash on WebRTC's signaling thread when a track was published while the room was disconnecting or reconnecting
- Data published right after `connect()` could be discarded without reporting an error in single peer connection and publisher-primary modes: the send path skipped the data channel open wait outside subscriber-primary, and a write handed to a channel that is still opening is evicted by the next one on the lossy channel's drop-oldest queue. Every send now waits for the specific channel (reliable or lossy) it will be written to, a send issued while the room is disconnected fails immediately instead of waiting out that timeout, and the first discarded write on a channel is now logged
- Fix the broadcast extension retrying the IPC connection in a busy loop
- Publish a broadcast started from the broadcast extension on iOS 27 through Broadcast Capture instead of presenting the ScreenCaptureKit picker, which stopped broadcasts started from Control Center
- Fix `VideoView` ending up attached to the wrong track, or to none, after rapid `track` / `isEnabled` changes; a burst of changes now costs at most one detach and one attach instead of one per change, and a view that is deallocated while attached detaches itself from the track (#1139)
- Fix the broadcast screen share capturer leaking when capture stops before the broadcast extension connects, and warn when more than one broadcast screen share is active
- Fail over to another LiveKit Cloud region when a connection is rejected with HTTP 403. Cloud signals project-level region pinning with a 403 on the RTC paths, which was previously treated as terminal, so a client that geo-routed to a disallowed region never reached one it was allowed to use (#1120)
- Fix a deadlock when a `waitUntilActive` / `waitUntilAnyActive` timeout fired at the moment the wait was cancelled, which could hang the app's task and a timer thread
- Declare the LiveKit target's direct dependency on CLiveKitProto so consumers that link each SwiftPM target as its own framework (e.g. Tuist) no longer fail with undefined nanopb descriptor symbols (#1126)
- Stop the broadcast extension when the automatic screen share publish fails, and report a disconnected room instead of a permission error when publishing
- Prefix the vendored nanopb header names, include guards and C type names (lk_pb.h, lk_pb_msgdesc_t) so a SwiftPM graph that also contains another nanopb -- Firebase's, or one the app imports directly -- no longer fails to compile (#1133)
- A pre-connect audio buffer flush that raced a late send could hand the flushed stream to a room that was not connected; the flush now takes the stream before the recorder reports stopped, so the late send is the silent no-op it is documented to be

## [2.17.0] - 2026-09-10

### Added

- RoomDelegate.room(_:didUpdateBufferStatus:of:) reports when a data channel's send buffer fills up or drains again, so publishers can back off
- Async variants of every local track creator (createTrack, createCameraTrack, createBufferTrack, createARCameraTrack, and the screen-share creators) that run WebRTC factory work on the RTC executor instead of blocking the calling thread; the synchronous variants are deprecated
- Data tracks: publish and subscribe to ordered frame streams over a dedicated unreliable channel, with optional schema and frame-encoding metadata

### Changed

- Vendored nanopb runtime updated from 0.4.9.1 to 0.4.9.2 (GHSA-p24j-vqcp-x988); the SDK's generated code has no callback fields, so it was not exposed to the oneof callback type confusion, and the wire format is unchanged
- Updated WebRTC to m150 branch
- iOS audio session: `.playAndRecord` is now kept until the audio engine stops, so muting the microphone no longer resets the category and disables Apple's echo cancellation mid-call; `.mixWithOthers` is no longer set on `.playAndRecord`, so publishing the microphone interrupts other apps' audio for the rest of the call (it remains set on `.playback`)
- Resolve the default video degradation preference from the track source (camera maintains framerate, screen share maintains resolution, others balanced) and apply it to the backup codec's sender as well
- Re-publishing local tracks after a reconnect or room move no longer stops at the first failing track: every track is attempted, each failure is logged with its source, and the first error is reported to the caller
- The lossy data channel now drops the oldest queued payload under sustained backpressure (more than 2MB buffered) instead of queueing without bound; a dropped send returns normally, and drops are counted and logged
- Replace SwiftProtobuf with a vendored nanopb-based protocol layer, reducing the SDK's app-size footprint by ~1.8 MB

### Fixed

- Screen sharing no longer fails to resume after a full reconnect: the capture source (iOS broadcast extension IPC, ReplayKit) is kept alive while the track is reattached to the new publisher
- A backup video codec is re-published after a full reconnect again: unpublishing a track now clears its per-codec senders, which previously kept pointing at the destroyed peer connection and made the SDK believe the codec was still being sent
- Re-publishing a video track after its capturer was stopped no longer times out waiting for dimensions: stopping a capturer now clears the cached dimensions, so a source that resumes at the same resolution resolves them again
- Data channel crypto is now installed uniformly and scoped to the connection: rooms using legacy E2EEOptions can decrypt incoming encrypted packets, a reused Room no longer inherits the previous connection's released crypto manager, and the negotiated data channel max-message-size resets between sessions
- Negotiate Opus stereo in the subscriber answer so stereo publications are no longer downmixed to mono when using custom renderers
- Roll back the sender when publishing fails after the track was added on the server (e.g. audio frame-watcher timeout), so the SFU no longer keeps an orphaned track that the client cannot mute or unpublish
- Received E2EE data messages reported their encryptionType as .none: decryption rewrites the packet's payload, which clears the field the type was read from
- Request microphone permission while foregrounded before enabling recording
- WebRTC calls that block on libwebrtc's threads now run on a dedicated RTC executor instead of Swift Concurrency's cooperative pool, so a stalled audio device or signaling thread no longer freezes the host app's tasks
- Reliable data sends could stall permanently after a full reconnect that happened while more than 2MB was buffered, and a reliable replay after a full reconnect could emit stale sequence numbers
- The v1 signal path's `join_request` parameter is now base64url-encoded instead of standard base64, so payloads containing `+` are no longer corrupted by receivers that parse the query as form-urlencoded, and it is gzip-compressed when that makes it smaller, keeping the WebSocket upgrade request inside a single TCP segment

## [2.16.0] - 2026-08-04

### Added

- Add `DevelopmentTokenSource`, the new name for the now-deprecated `SandboxTokenSource`
- Add `BaseKeyProvider.setKey(keyData:participantId:index:)` for installing raw binary E2EE key material without String conversion

### Changed

- Encapsulate SDP munging in a tested SDP module and fall back to the unmunged offer if libwebrtc rejects munged SDP

### Fixed

- Use media session mode when recording with software voice processing to fix quiet remote audio
- Pre-connect audio buffer could be sent before the microphone publish resolved its track sid, arriving at the agent without a trackId and being dropped
- Incoming data streams could be dropped on stream-ID reuse or handled out of order; transcription handlers now run in wire order and open streams are failed on sender disconnect and room cleanup
- Completer timeouts and camera device discovery no longer run at background QoS, which the system may defer indefinitely under load

## [2.15.3] - 2026-07-27

### Fixed

- Remove non-public buttonPressed: selector from broadcast picker activation

## [2.15.2] - 2026-07-17

### Added

- Add `LocalParticipant.publishDtmf(code:digit:)` for sending SIP DTMF tones
- Add AudioProcessingOptions

### Fixed

- Ping/pong timeout was re-armed on every ping and never fired, leaving a lost signaling connection stuck at .connected
- WebRTC crashes during track teardown
- Report microphone permission and audio session errors with the correct error type

## [2.15.1] - 2026-06-18

### Fixed

- Fixed Xcode 27 beta build errors
- Fixed WebRTC use-after-free buffer crash
- Wrap ObjC completion-handler async calls in explicit checked continuations (fixes mixed Swift 5/6 continuation-bridge EXC_BAD_ACCESS)

## [2.15.0] - 2026-06-09

### Added

- Expose `keyDerivationAlgorithm` (PBKDF2/HKDF) and `discardFrameWhenCryptorNotReady` on `KeyProviderOptions` for parity with Android
- RPC v2: transport payloads larger than 15 KB over data streams when both peers support it
- Allow customizing `maxRoundTripLatency` on `LocalParticipant.performRpc` for high-latency networks

### Changed

- Bumped minimum Swift toolchain to 6.1 (Xcode 16.3+)

### Fixed

- `Room.sid()` no longer resolves with an empty SID
- Reliable data-channel sequence stays monotonic under concurrent sends
- Crashes during track teardown in WebRTC m144
- Crash on PeerConnection teardown caused by DTLS-in-STUN piggyback field trial
- Fix adaptive stream dimensions on high-density displays
- Camera position lost after full reconnect
- Advertise both ConstrainedHigh and ConstrainedBaseline H264 profiles instead of collapsing to ConstrainedBaseline L5.0
- Reject oversized data messages before they break the publisher data channel
- Clamp simulcast lower-layer maxFps to the top layer, and clamp maxBitrate for layers that don't scale resolution down, so the user-configured top layer is always the highest-quality tier

## [2.14.1] - 2026-05-13

### Fixed

- Report transport-level disconnects as LiveKitError(.network) instead of LiveKitError(.cancelled) so consumers can distinguish network failures from user-initiated cancellation
- Faster initial connect in single peer connection mode by skipping an unnecessary 20ms negotiate debounce
- Fix RemoteAudioTrack volume range

## [2.14.0] - 2026-04-29

### Added

- Configure end-to-end encryption directly through Session initialization

### Changed

- Drop Xcode 15 (Swift 5.x) support; minimum is now Xcode 16 / Swift 6.0
- Skip AVAudioSession configuration in manual rendering mode

### Fixed

- Avoid Metal pipeline freeze on iPhone 11 family by defaulting to sample buffer renderer

## [2.13.0] - 2026-04-09

### Added

- Single peer connection mode via `RoomOptions.singlePeerConnection`. Requires LiveKit Cloud or LiveKit OSS >= 1.9.2.
- Missing data stream and RPC ObjC exposure with ObjC tests
- SoundPlayer API for prepared audio clips with local playback and best-effort remote playback
- Add isFinal property to ReceivedMessage for transcription segment finalization

### Changed

- Changed minimal supported visionOS version to 26 due to WebRTC dependencies
- Update WebRTC to m144
- Remove swift-collections dependency by replacing with minimal internal implementations

### Fixed

- Local video track freezing during landscape rotation or losing aspect ratio
- Use software rendering in BroadcastImageCodec to avoid GPU crash when app is backgrounded during PiP
- Correct sample-buffer rendering for cropped and scaled screen-share frames
- WebSocket failing to connect in some concurrent scenarios
- Stop audio publishing when audio session activation fails by propagating configuration errors to the audio engine
- Set maximumFramesToRender on mixer audio nodes to prevent kAudioUnitErr_TooManyFramesToProcess (-10874) when iOS negotiates larger IO buffer sizes
- Crash during PeerConnection teardown caused by stats timer race
- Screen share via broadcast extension showing 3fps on receiver due to hardcoded simulcast layer FPS
- WebSocket errors killing new connections

## [2.12.1] - 2026-02-17

### Fixed

- Voice Processing failing on iOS devices
- Missing objc annotations for some objc class members

## [2.12.0] - 2026-02-11

### Added

- Expose separate bitrate/network priorities for media tracks

### Changed

- Add option to disable automatic audio session deactivation
- Default other-audio-ducking configuration

### Fixed

- Linker warnings from FFI package
- Crashes on macOS Catalyst
- Reset/stop mixer player nodes on audio engine start/stop
- Camera selection changing after full reconnect

## [2.11.0] - 2026-01-12

### Added

- Prepare connection & region pinning
- Experimental support and bindings for shared Rust crates using UniFFI
- Handle Room moved event

### Changed

- Default protocol version to v16
- Minor validation logic improvements

### Fixed

- Memory leaks in data channel cancellation code
- Reconnect sequence stuck in failed state
- Crash audio processing adapter during deinit

## [2.10.2] - 2025-12-10

### Fixed

- Screen sharing not publishing frames with VP9/AV1 codecs
- Crash in VideoView when video dimensions are both 0
- Crash when moving apps to background during broadcast
- Crash in LocalAudioTrack.deinit
- Default degradation preference for non-simulcast tracks
- Race condition during sync preventing track subscription

## [2.10.1] - 2025-11-26

### Changed

- Allowed Agent recovery from failed state
- Removed '@unchecked Sendable' extensions on common types

### Fixed

- Timeouts when publishing camera tracks
- Processing data packets out-of-order leading to stream corruption

## [2.10.0] - 2025-11-13

### Added

- Separate delegate methods for reconnect start/completion
- Agent and Session APIs for creating agent-based apps

### Fixed

- Improved capture format logic for multicam devices

## [2.9.0] - 2025-10-20

### Added

- Improved logging with the interface for custom loggers
- Add lastSpokeAt property to Participant
- Abstract token source for easier token fetching in production and faster integration with sandbox environment

### Fixed

- clamp response timeout in performRpc to minimal 1s
- Audio processing delegate lifecycle
- Byte stream MIME type defaulting to text/plain
- App extension compile issues
- Breaking change: Library evolution support (xcframework). May break existing `*Track` extensions.
- Serial operations cancellation semantics

## [2.8.1] - 2025-10-02

### Fixed

- RoomOptions init collision

## [2.8.0] - 2025-10-01

### Added

- Added support for data channel encryption, deprecated existing E2EE options
- Added audio engine availability control
- Added .disconnected connection state

### Changed

- Auth token in header instead of query param
- Audio capturing for manual rendering mode

### Fixed

- Renderer lifecycle in the video view causing flickering effect
- Restrict transceiver memory leak fix to video tracks
- Screen sharing getting stuck on macOS when the display is turned off
- Only check audio recording perms for device rendering mode
- Fixed race condition between reconnect and disconnect leading to failed disconnects

## [2.7.2] - 2025-08-29

### Fixed

- Fixed transceiver crash, reverting video memory leak changes

## [2.7.1] - 2025-08-25

### Added

- Recording permission check at SDK level

### Changed

- Expose audio capture API

### Fixed

- Remote audio buffer when using manual rendering mode

## [2.7.0] - 2025-08-21

### Added

- outputVolume property to audio mixer
- Added the possibility to exlude macOS windows from screen sharing
- HEVC (H.265) codec support
- Added wait until active APIs for RemoteParticipant

### Changed

- Improved reliability of the data channel
- Drop Xcode 14 (Swift 5.7) support
- Updated webrtc to m137

### Fixed

- Fixed concurrent registration for text/byte streams
- macOS audio start workarounds
- Fixed WebSocket memory leak after disconnecting
- Fixed memory leak while unpublishing video tracks

## [2.6.1] - 2025-06-17

### Fixed

- Fixed Xcode 26 build errors with Swift 6.2
- Remove problematic KeyPath conformance to Sendable
- Fix race condition during remote track deinit
- Fix WebRTC symbol clash

### Changed

- Update audio session logic
- Flag to disable automatic audio session configuration

## [2.6.0] - 2025-05-15

### Added

- New API to capture pre-connect audio and send it to agents
- Added BackgroundBlurVideoProcessor
- New mic mute mode

### Changed

- Ensure audio frames are being generated when publishing audio
- Update to protobuf v1.37.0

### Fixed

- Sendable requirement for internal callbacks

## [2.5.1] - 2025-04-23

### Added

- Added the possibility to compile Swift v6 package in v5 mode

### Fixed

- Add OrderedCollections as Cocoapods dependency
- Fixed crash in VideoView computed property access
- Fixed crash in VideoView.isHidden property access

## [2.5.0] - 2025-04-18

### Added

- Audio mix recorder
- Exposed reconnect mode in RoomDelegate
- Concurrent mic publishing when connecting
- Added the ability to send RTC metrics
- Added internal flags to measure StateSync performance

### Changed

- Use millisecond precision for Date
- Fast track publishing
- Improve reconnect delay logic
- Changed lock types used for internal synchronization
- Minor SignalClient improvements
- Refactored mute api
- Swift 6: Added Sendable requirement to all delegate protocols
- Added Swift 6 support

### Fixed

- Swift 6: Fixed warnings for MulticastDelegate and related classes
- Swift 6: Fixed warnings for (Local/Remote) Participant and stream handlers
- Swift 6: Fixed warnings for some of the internal RTC classes
- Swift 6: Fixed warnings for mutable state
- Swift 6: Fixed crash in VideoView with .v6 language mode
- Swift 6: Fixed warnings in VideoView and SwiftUIVideoView

## [2.4.0] - 2025-03-21

### Added

- Added missing RED option to AudioPublishOptions
- Added LocalAudioTrackRecorder
- Added the possibility to capture pre-connect audio and send it to agents via data streams

### Removed

- Removed unnecessary logs from stream handlers

### Fixed

- Explicit AudioManager initialization
- Metal renderer scale factor
- Wrong stream timestamp conversion
- Race condition in WebSocket impl

## [2.3.1] - 2025-03-11

### Changed

- Update default audio capture options for Simulator

### Fixed

- Audio engine node detach crash

## [2.3.0] - 2025-03-10

### Added

- ParticipantPermissions exposes canPublishSources
- Data streams: initial support
- Data streams: chunk text along UTF-8 boundaries

### Changed

- RPC register method is now throwing
- RPC registration methods moved to Room

### Deprecated

- RPC registration methods on LocalParticipant deprecated

### Fixed

- Avoid audio engine crash
- Publishing tracks now checks participant permissions and throws an error for insufficient permissions
