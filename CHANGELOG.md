# Changelog

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
