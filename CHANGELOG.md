# Changelog

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
