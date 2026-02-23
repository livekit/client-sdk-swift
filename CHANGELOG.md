# Changelog

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
