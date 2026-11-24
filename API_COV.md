# API coverage: LiveKit Swift API over the Rust WebRTC backend

This file tracks how much of the v2.20.0 public API works on the Rust backend.
The baseline is commit `2fcaec9c` (tag `v2.20.0`). The goal is the same public
API with Rust `livekit-ffi` (`room-apis`) as the owner of WebRTC and signaling.

## Status words

| Status | Meaning |
|---|---|
| pending | Not ported. The code is still the v2.20.0 Swift WebRTC path. |
| implemented | Real behavior on the Rust path, proved by a test that this file names. |
| compile-only | The declaration is kept. The behavior is absent or not proved. |
| stub | The call throws a documented "unsupported" error. |
| blocked | No honest implementation is possible inside the Swift repository and the Rust FFI crate. |

An existing Rust FFI operation does not make a row implemented. Only a test does.

## Baseline surface

Source: `swift-api-digester` dump and the compiler-generated Objective-C header.
The saved files are in `/Users/blaze/livekit/research-v3/swift-baseline` (not committed).

| Measure | macOS arm64 | iOS arm64 |
|---|---|---|
| Public LiveKit types | 246 (115 classes, 56 enums, 38 protocols, 37 structs) | 246 |
| Functions | 575 | 590 |
| Initializers | 223 | 224 |
| Properties | 1148 | 1159 |
| Enum cases | 353 | 354 |
| Objective-C classes, protocols, enums | 96, 24, 30 | 95, 23, 29 |
| Objective-C methods, properties | 577, 452 | 585, 439 |
| `@optional` sections in the header | 8 | 8 |

Each platform has 6 types that the other platform does not have. macOS has the
`MacOS*` screen capture types. iOS has `BroadcastManager`, `IOSScreenCapturer`,
`LKSampleHandler` and the audio session types.

To compare a later build with the baseline:

```zsh
.github/api-check/api-dump.sh /tmp/head macOS
.github/api-check/api-dump.sh --diff /Users/blaze/livekit/research-v3/swift-baseline/macOS /tmp/head/macOS
```

The first command builds the checkout and saves its surface. The second command
writes `breaking.txt`, `additions-reversed.txt` and `objc-header.diff`. Read all
three reports. When the digester finds a break, its exit code is still 0.

## Coverage by group

All rows are pending at the baseline. The "Expected" column is a forecast, not a result.

| Group | Baseline surface | Rust `room-apis` operation today | Status | Expected | Gap |
|---|---|---|---|---|---|
| Room connect, state, events (`Core`, `RoomDelegate`) | 6 types, 90 members | `connect`, `disconnect`, room events | pending | implemented | See "Connect options" below. |
| Participants (`Participant`) | 3 types, 90 members | initial entities, participant events, `set_local_metadata`, `set_local_name`, `set_local_attributes` | pending | implemented | Object identity and Objective-C selectors must stay. |
| Publications and tracks (`TrackPublications`, `Track`) | 26 types, 201 members | `publish_track`, `unpublish_track`, `local_track_mute`, `set_subscribed`, `enable_remote_track`, dimension and quality updates, `get_stats` | pending | implemented, 1 stub | `set(preferredFPS:)` has no Rust operation. |
| Video capture and render (`Track/Capturers`, `Views`, `SwiftUI`, `VideoProcessors`) | 6 types, 102 members plus capturers | `new_video_source`, `capture_video_frame`, `new_video_stream` | pending | implemented on macOS and iOS | Rust has no camera or screen capture for Apple. Swift capturers must feed frames. |
| Audio (`Audio`, `Convenience`) | 13 types, 138 members | `new_audio_source`, `capture_audio_frame`, `new_audio_stream`, `new_platform_audio`, device requests, `new_apm` | pending | mixed | See "Audio engine" below. |
| Data packets, DTMF, transcription (`Agent`) | 7 types, 53 members | `publish_data`, `publish_sip_dtmf`, `publish_transcription` | pending | implemented | None known. |
| RPC | part of `Participant` | `perform_rpc`, `register_rpc_method`, `unregister_rpc_method` | pending | implemented | Not proved for RPC v2 and cancellation. |
| Data streams (`DataStream`) | 12 types, 131 members | byte and text stream requests, `send_file`, `send_text`, `send_bytes` | pending | implemented | Today Swift uses the `core-modules` stream managers. These do not exist in `room-apis`. |
| Data tracks (`DataTrack`) | 13 types, 107 members | `publish_data_track`, `subscribe_data_track`, `data_track_stream_read`, `define_schema`, `get_schema` | pending | implemented | Same as data streams. |
| E2EE (`E2EE`) | 9 types, 84 members | E2EE manager, key provider and frame cryptor requests | pending | implemented | Custom `KeyProvider` behavior is not proved. |
| Token, log, version (`Token`, `Support`, `LiveKit.swift`) | 30 types, 141 members | none in `room-apis` | pending | implemented after re-export | See "Helpers to export again". |
| Value types (`Types`, `Errors`, `Protocols`) | 121 types, 1057 members | not needed | pending | implemented | These are plain Swift declarations. They must not change. |
| Protocol layer (`Protos`, `CLiveKitProto`) | 114 C structs seen by the digester | not needed | pending | compile-only | If Swift removes this layer, the digester reports 114 removed conformances. Keep it compiled. |

## Exact gaps known at the baseline

### No Rust FFI operation

| Swift signature | Location | Expected | Alternative |
|---|---|---|---|
| `RemoteTrackPublication.set(preferredFPS newValue: UInt) async throws` | `TrackPublications/RemoteTrackPublication.swift:101` | stub | Add the field to the Rust core. That is outside the FFI crate. |
| `RemoteAudioTrack.volume: Double { get set }` | `Track/Remote/RemoteAudioTrack.swift:36` | blocked | If Swift owns playout of the PCM stream, apply gain in Swift. |

### Connect options with no Rust field

Rust `RoomOptions` has `auto_subscribe`, `adaptive_stream`, `dynacast`, `encryption`, `rtc_config`, `join_retries`, `single_peer_connection`, `connect_timeout_ms` and `data_stream`.

| Swift property | Expected |
|---|---|
| `ConnectOptions.reconnectAttempts: Int` | compile-only |
| `ConnectOptions.reconnectAttemptDelay: TimeInterval` | compile-only |
| `ConnectOptions.reconnectMaxDelay: TimeInterval` | compile-only |
| `ConnectOptions.primaryTransportConnectTimeout: TimeInterval` | compile-only |
| `ConnectOptions.publisherTransportConnectTimeout: TimeInterval` | compile-only |
| `ConnectOptions.isDscpEnabled: Bool` | compile-only |
| `ConnectOptions.protocolVersion: ProtocolVersion` | compile-only |
| `ConnectOptions.clientProtocol: ClientProtocol` | compile-only |
| `VideoPublishOptions.simulcastLayers: [VideoParameters]` | compile-only |
| `VideoPublishOptions.screenShareSimulcastLayers: [VideoParameters]` | compile-only |
| `VideoPublishOptions.preferredBackupCodec: VideoCodec?` | compile-only |

Open decision: `Room.connect` throws, so a non-default value can fail there instead of being ignored.

### Audio engine

These APIs need the real `AVAudioEngine` graph. Rust owns the audio device, so Swift has no graph to give.

| Swift signature | Location | Expected |
|---|---|---|
| `AudioManager.setManualRenderingMode(_ enabled: Bool) throws` | `Audio/Manager/AudioManager.swift:410` | stub |
| `AudioManager.setPlatformVoiceProcessingAllowed(_ allowed: Bool) throws` | `Audio/Manager/AudioManager.swift:338` | stub |
| `LocalAudioTrack.setAudioProcessingOptions(_ options: AudioProcessingOptions) throws -> AudioProcessingOptionsResult` | `Track/Local/LocalAudioTrack.swift:124` | stub |
| `AudioManager.set(engineObservers: [any AudioEngineObserver])` | `Audio/Manager/AudioManager.swift:510` | blocked |
| `AudioManager.capturePostProcessingDelegate: AudioCustomProcessingDelegate?` | `Audio/Manager/AudioManager.swift:212` | blocked |
| `AudioManager.renderPreProcessingDelegate: AudioCustomProcessingDelegate?` | `Audio/Manager/AudioManager.swift:223` | blocked |
| `AudioManager.isVoiceProcessingBypassed: Bool { get set }` | `Audio/Manager/AudioManager.swift:366` | blocked |
| `AudioManager.isVoiceProcessingAGCEnabled: Bool { get set }` | `Audio/Manager/AudioManager.swift:386` | blocked |
| `AudioManager.mixer: MixerEngineObserver` | `Audio/Manager/AudioManager.swift:543` | blocked |

The non-throwing rows cannot report an error. They stay blocked until Rust exposes the engine or Swift owns the audio device.

### Platforms

The package declares iOS, macOS, Mac Catalyst, tvOS and visionOS. The Rust WebRTC
build script maps only `mac`, `ios-device` and `ios-simulator`. Expected: tvOS,
visionOS and Mac Catalyst are blocked until a prebuilt WebRTC exists for them.

## Helpers to export again

Swift v2.20.0 already links `LiveKitFFI` 0.13.4 built with `core-modules`. That
feature cannot be on together with `room-apis`. The Swift sources use 65 names
from it. The names below have no equivalent in `room-apis` today.

| Helper | Swift user | Needed on the Rust path |
|---|---|---|
| `logForwardBootstrap(level:)`, `logForwardReceive()`, `LogForwardFilter`, `LogForwardLevel` | `Support/Logger.swift` | Yes |
| `tokenClaimsFromUnverified`, `Claims`, `RoomConfiguration`, `RoomAgentDispatch` | `Token/TokenSource.swift` | Yes |
| `tokenGenerate`, `TokenOptions`, `VideoGrants`, `ApiCredentials` | tests and benchmarks only | Yes, for the test targets |
| `setWsClient`, `setHttpClient`, `WsClient`, `WsConnection`, `HttpClient`, `TransportError` (`livekit-net`) | `Support/Network/RustTransport.swift` | Yes, or Rust uses its own socket and TLS code |
| `buildVersion()` | `LiveKit.swift` | Already shared by both features |
| Stream and data track managers, records and delegates (about 35 names) | `DataStream`, `DataTrack`, `Core/RoomDependencies.swift` | No. The Rust room replaces them. |
| `EncryptionProvider`, `DecryptionProvider`, `EncryptedPayload` | `E2EE/DataTrackE2EE.swift` | Open. It depends on how the Rust room encrypts data tracks. |

The full name lists are in `/Users/blaze/livekit/research-v3/swift-baseline/ffi-usage`.
