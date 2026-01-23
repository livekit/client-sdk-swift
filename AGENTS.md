# LiveKit Swift SDK

## Commands

Supported platforms: macOS (use for platform-agnostic code), macOS Catalyst, iOS, visionOS, tvOS.
Platform destinations: `macOS`, `macOS,variant=Mac Catalyst`, `iOS Simulator`, `visionOS Simulator`, `tvOS Simulator`.

```zsh
# Build
xcodebuild build -scheme LiveKit -destination 'platform=macOS'

# Run tests (requires local server: livekit-server --dev, install via brew install livekit)
xcodebuild test -scheme LiveKit -only-testing LiveKitCoreTests -destination 'platform=macOS'

# List available simulators for platform-specific builds
xcrun simctl list devices
```

## Architecture

```
Sources/LiveKit/
├── Core/                  # Room, SignalClient, Transport (WebRTC peer connections)
├── Participant/           # LocalParticipant, RemoteParticipant
├── Track/                 # LocalAudioTrack, LocalVideoTrack, RemoteTrack, Capturers
├── TrackPublications/     # TrackPublication, LocalTrackPublication, RemoteTrackPublication
├── Audio/                 # AudioManager, AudioDeviceModule integration
├── Broadcast/             # Screen sharing via ReplayKit (iOS/macOS)
├── DataStream/            # Reliable/unreliable data channels, byte/text streams
├── E2EE/                  # End-to-end encryption
├── Agent/                 # AI agent integration (transcription, speech activity)
├── Token/                 # TokenSource implementations for auth
├── Types/                 # Public types, options, enums
├── Protocols/             # RoomDelegate, ParticipantDelegate, TrackDelegate, etc.
├── Support/
│   ├── Async/             # AsyncCompleter, AsyncTimer, AsyncSequence+Subscribe
│   ├── Sync/              # StateSync, Locks (thread-safe state management)
│   ├── Schedulers/        # QueueActor, SerialRunnerActor (ordered execution)
│   ├── Network/           # WebSocket, HTTP, ConnectivityListener
│   └── Audio/Video/       # Audio converters, device management
├── SwiftUI/               # SwiftUIVideoView, LocalMedia
├── Views/                 # VideoView, SampleBufferVideoRenderer
└── Protos/                # Generated protobuf types (excluded from linting)
```

Key components:

- `Room` - main entry point; manages connection state, participants, and tracks via `StateSync`
- `Participant` - base class for `LocalParticipant`/`RemoteParticipant`; holds track publications
- `SignalClient` - WebSocket connection to LiveKit server; handles signaling protocol as an `actor`
- `Transport` - WebRTC `PeerConnection` wrapper; manages ICE, SDP negotiation as an `actor`
- `StateSync<T>` - thread-safe state container with `@dynamicMemberLookup`; triggers `onDidMutate` callbacks
- `MulticastDelegate<T>` - weak-reference delegate collection for event broadcasting

Dependencies: LiveKitWebRTC, LiveKitUniFFI, SwiftProtobuf, swift-collections.

## WebRTC

WebRTC handles the actual media transport (audio/video/data) between participants. The SDK abstracts WebRTC complexity behind `Room`, `Participant`, and `Track` APIs while LiveKit server coordinates signaling.

Key files:

- `Core/RTC.swift` - factory for creating WebRTC objects (peer connections, tracks, data channels, etc.)
- `Core/Transport.swift` - wraps `LKRTCPeerConnection`; handles ICE candidates, SDP offer/answer
- `Audio/Manager/` - `AudioManager` and `AudioDeviceModule` integration
- `Extensions/RTC*.swift` - convenience extensions on WebRTC types

Threading:

- All WebRTC API calls must use `DispatchQueue.liveKitWebRTC.sync { ... }` for thread safety
- WebRTC types are accessed via `internal import LiveKitWebRTC` to keep them private from public API

## Testing

- `LiveKitCoreTests` - unit tests and E2E tests; run on macOS or simulators
- `LiveKitAudioTests` - audio tests requiring real device with microphone access
- `LiveKitObjCTests` - Obj-C interoperability validation
- `LiveKitTestSupport` - test utilities including `withRooms` helper for multi-participant E2E tests
- E2E tests use `withRooms([...]) { rooms in ... }` to spawn multiple connected rooms/participants
- E2E tests should cover reconnects, partial updates, edge cases, and stress scenarios

## Using Swift

### Language Version

- Supported Xcode versions: current minus two major versions (including beta)
- `Package.swift` and `.swift-version` declare the **oldest** supported version (e.g., `swift-tools-version:5.9`) for backwards compatibility
- Keep all manifests in sync when adding dependencies
- New code should use the latest stable Swift version
- Some constructs require `#if swift` or `#if compiler` directives for version compatibility:

```swift
#if swift(>=6.0)
public nonisolated(unsafe) static let shared = AudioManager()
#else
public static let shared = AudioManager()
#endif
```

### Concurrency and State

- The SDK uses Swift 6 concurrency and data-race safety
- Most features (excluding UI like `VideoView`) perform async work on **background** threads
- Internal entities communicate via `async` calls, `AsyncSequence`/`AsyncStream`, and `actor` for synchronization
- Network connections and async sources can be modeled as `AsyncSequence`
- Delegates and closures should only bridge to public APIs (e.g., `RoomDelegate`)
- `actor` can use `nonisolated` entry points to integrate with `public` code
- A common pattern is an internal "event loop" to process incoming data in FIFO order
- For synchronous/`nonisolated` APIs (getters), use `StateSync` with locking and `@unchecked Sendable` (see `Support/Sync`)
- Do not add any new synchronization primitives (locks, queues)
- Minimize lock contention by grouping reads/writes under one `state.mutate { ... }` call
- `@unchecked Sendable` on a class requires reviewing its internals for synchronization
- Avoid `@MainActor` for synchronization of static members in non-UI components
- Long-running `Task` requires cooperative cancellation to avoid memory leaks (e.g., `AsyncSequence.subscribe`)
- Use `AnyTaskCancellable` (via `task.cancellable()`) instead of manual `Task` management (enforced by SwiftLint)
- Use async primitives in `Support/Async` and `Support/Schedulers` when operation order matters
- Prefer native Swift async/await over `Combine` for new code

### Error Handling

- Crashing consumer code via `fatalError()` and similar assertions is **not allowed**
- `assert()`/`precondition()` should be avoided
- For recoverable errors, consider defensive programming first (retry, backoff, graceful failure)
- For non-recoverable errors, propagate with `throws` using `LiveKitError` with proper type/code
- Anticipate invalid states at compile time using algebraic data types, typestates, etc.
- Unsafe APIs like subscript `[0]` should be wrapped and leverage optional `?`

### Coding Style

- Consistency across features is more important than latest syntactic sugar
- Run `swiftlint` (see `.swiftlint.yml`); **do not** introduce new warnings
- Try to remove `// swiftlint:disable` in legacy files by refactoring
- Deprecation warnings are allowed in public APIs; do not fix them
- `// Code comments` should be used sparingly; prefer better naming/structuring
- Do not add trivial "what" comments like `// Here is the change`
- `/// Docstrings` for **every** public API using Swift markdown (`- Note`, `- Warning`, `- SeeAlso`, etc.)
- Add short code examples for new APIs to the entry point (e.g., `Room` class)
- `Loggable` logs use `.debug` by default; `.warning`/`.error` only for consumer-facing issues
- Remove `_privateFields` naming inconsistencies when touching surrounding code

### SwiftUI

- If an object conforms to `ObservableObject`, make sure changes are published
- It may require manually calling `objectWillChange.send()` combined with `StateSync` on `@MainActor`

### Obj-C Support

- **Public** APIs should support Obj-C with `@objc` at class level
- This restricts Swift types (no enums with associated values, structs, async primitives)
- Internal/private APIs should **not** support Obj-C unless required; use Swift's type system
- If Obj-C leads to awkward patterns, wrap Swift in additional layers rather than sacrificing Swift APIs

<skills_system priority="1">

## Available Skills

<!-- SKILLS_TABLE_START -->
<usage>
When users ask you to perform tasks, check if any of the available skills below can help complete the task more effectively. Skills provide specialized capabilities and domain knowledge.

How to use skills:
- Invoke: `npx openskills read <skill-name>` (run in your shell)
  - For multiple: `npx openskills read skill-one,skill-two`
- The skill content will load with detailed instructions on how to complete the task
- Base directory provided in output for resolving bundled resources (references/, scripts/, assets/)

Usage notes:
- Only use skills listed in <available_skills> below
- Do not invoke a skill that is already loaded in your context
- Each skill invocation is stateless
</usage>

<available_skills>

<skill>
<name>swift-concurrency</name>
<description>'Expert guidance on Swift Concurrency best practices, patterns, and implementation. Use when developers mention: (1) Swift Concurrency, async/await, actors, or tasks, (2) "use Swift Concurrency" or "modern concurrency patterns", (3) migrating to Swift 6, (4) data races or thread safety issues, (5) refactoring closures to async/await, (6) @MainActor, Sendable, or actor isolation, (7) concurrent code architecture or performance optimization, (8) concurrency-related linter warnings (SwiftLint or similar; e.g. async_without_await, Sendable/actor isolation/MainActor lint).'</description>
<location>global</location>
</skill>

</available_skills>
<!-- SKILLS_TABLE_END -->

</skills_system>
