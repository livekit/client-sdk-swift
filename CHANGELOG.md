# Changelog

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
