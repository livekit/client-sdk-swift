# LiveKit Swift SDK

## Commands

Supported platforms: macOS (use for platform-agnostic code), macOS Catalyst, iOS, visionOS, tvOS.
Platform destinations: `macOS`, `macOS,variant=Mac Catalyst`, `iOS Simulator`, `visionOS Simulator`, `tvOS Simulator`.

```zsh
# Build
xcodebuild build -scheme LiveKit -destination 'platform=macOS'

# Run tests (requires local server, install via brew install livekit). Data track schema tests
# need participant data blobs, which --dev alone leaves off:
#   printf 'enable_participant_data_blob: true\n' > lk.yaml && livekit-server --dev --config lk.yaml
xcodebuild test -scheme LiveKit -only-testing LiveKitCoreTests -destination 'platform=macOS'

# Build benchmarks
cd Benchmarks && swiftly run +xcode swift build

# Run benchmarks (requires local server: livekit-server --dev)
cd Benchmarks && LK_BENCHMARK=1 swiftly run +xcode swift package --disable-sandbox benchmark

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

Dependencies: LiveKitWebRTC, LiveKitUniFFI. (SwiftProtobuf is test-only — see below.)

## Protocol Layer (protobuf)

The wire protocol is nanopb-based, not SwiftProtobuf: generated C in
`Sources/CLiveKitProto`, a fixed-cost Swift runtime in `Sources/LiveKitNanopb`,
and generated facades in `Sources/LiveKit/Protos`. Every message is the one
generic `NanopbMsg<Storage>`, so the schema contributes no Swift types;
`Livekit_Room` is a typealias. Messages are immutable — build with `.with { }`.

**See [PROTOCOL.md](PROTOCOL.md)** for the update workflow, the design and its
constraints, memory/concurrency semantics, and the invariants to preserve when
editing. Regenerate with `make proto`; never edit generated files by hand.

## Compile-Time Flags

- `LK_XCFRAMEWORK` — set in the generated xcodeproj by `scripts/xcframework.swift`; that build compiles `CLiveKitProto`/`LiveKitNanopb` sources into the framework target directly, so the guards in those files switch to `internal`/`package import CLiveKitProto` (resolved via its modulemap) and drop `import LiveKitNanopb`, keeping both out of the emitted `.swiftinterface`
- `LK_BENCHMARK` — set when building benchmarks (`Benchmarks/`); skips `DeviceManager`/`AudioManager` init in `Room.init` to allow headless benchmark runs
- `LK_SIGNPOSTS` — enables `os.signpost` instrumentation in `StateSync` for profiling lock contention in Instruments

## WebRTC

WebRTC handles the actual media transport (audio/video/data) between participants. The SDK abstracts WebRTC complexity behind `Room`, `Participant`, and `Track` APIs while LiveKit server coordinates signaling.

Key files:

- `Core/RTC.swift` - factory for creating WebRTC objects (peer connections, tracks, data channels, etc.)
- `Core/Transport.swift` - wraps `LKRTCPeerConnection`; handles ICE candidates, SDP offer/answer
- `Audio/Manager/` - `AudioManager` and `AudioDeviceModule` integration
- `Extensions/RTC*.swift` - convenience extensions on WebRTC types

Threading:

- libwebrtc's API objects are proxies: every call — and the release of the last reference — is a
  `BlockingCall` onto WebRTC's signaling/worker/network thread, which can stall. libwebrtc
  serializes those calls itself; the SDK adds no caller-side serialization for thread safety
- Thread-safety is not liveness: a blocking WebRTC call must never run on Swift Concurrency's
  width-limited cooperative pool. It runs inside the `@RTC` global actor (`Core/RTC.swift`), whose
  executor is a private dispatch queue that is allowed to block. `Transport` is `@RTC`-isolated;
  other async code wraps such calls in `await RTC.run { }`. `DispatchQueue.liveKitWebRTC` is
  deprecated public API
- Releases and teardown (`deinit`, `parkChannelRelease`) go to `RTC.park`, which runs them on a
  *concurrent* queue — not the serial `@RTC` executor. A release flood is a flood of blocking
  destructors; routing it through the one serial executor head-of-lines all other RTC work and
  wedged CI under the sanitizers
- Public synchronous APIs that reach WebRTC (the deprecated `create*Track` creators, `AudioManager`,
  `volume`, renderer attach) block their caller by documented contract — say so in the docstring;
  new API should be `async` and hop instead
- The `@RTC` executor carries no priority: every hop runs at the queue's `.default` QoS
- Exception, by design: the data-channel send path (`sendData`, `readyState`, `LKRTCDataBuffer`
  construction) is `nonisolated` — it is per-packet and latency-sensitive; `sendData` blocks only on
  the network thread (`PROXY_SECONDARY_*`), `readyState` is `BYPASS`, the buffer init is a plain
  byte container
- Completion handlers written inside `@RTC` code must be `@Sendable`: a non-Sendable closure
  inherits `@RTC` isolation, and WebRTC invokes it on its own threads — Swift 6.1-built binaries
  enforce that in the closure prologue and trap (Xcode 16.4 CI caught exactly this)
- WebRTC types are accessed via `internal import LiveKitWebRTC` to keep them private from public API

## Testing

- `LiveKitCoreTests` - unit tests and E2E tests; run on macOS or simulators
- `LiveKitAudioTests` - audio tests requiring real device with microphone access
- `LiveKitObjCTests` - Obj-C interoperability validation
- `LiveKitTestSupport` - test utilities including `withRooms` helper for multi-participant E2E tests
- E2E tests use `withRooms([...]) { rooms in ... }` to spawn multiple connected rooms/participants
- E2E tests should cover reconnects, partial updates, edge cases, and stress scenarios
- `@Test(.spec("https://..."))` cross-references a test to an upstream spec case via a pinned URL (commit + line anchor)

## Using Swift

### Language Version

- Minimum supported Xcode is Xcode 16.3 (Swift 6.1); see Apple's [App Store submission requirements](https://developer.apple.com/news/upcoming-requirements/?id=02212025a)
- `Package.swift` (`swift-tools-version:6.1`) declares the **oldest** supported version
- Keep `Package.swift`, `LiveKitClient.podspec`, and `.swiftformat`'s `--swiftversion` in sync when changing the minimum
- New code should use the latest stable Swift version
- Some constructs require `#if swift` or `#if compiler` directives to support newer-than-minimum toolchains:

```swift
#if swift(>=6.2)
private static let playAndRecordOptions: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay]
#else
private static let playAndRecordOptions: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP, .allowAirPlay]
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
- Fire-and-forget unstructured tasks that may throw must use `Task.discarding` / `Task.detachedDiscarding`; bare `Task { try await ... }` silently drops errors and is flagged under Swift main-snapshot (`#NoUseUnstructuredThrowingTask`)
- Only `Task.discarding` preserves caller actor isolation in its closure; other `Support/Async/` helpers (`Task.retrying`, `AsyncSerialDelegate.notifyAsync`, etc.) run their bodies nonisolated — hop explicitly with `await MainActor.run { ... }` when UI-bound work is needed
- Use async primitives in `Support/Async` and `Support/Schedulers` when operation order matters
- Prefer native Swift async/await over `Combine` for new code
- Until the minimum supported compiler is Swift 6.3, wrap calls to imported Objective-C completion-handler methods made via their synthesized `async` overload in an explicit `withCheckedThrowingContinuation`, since the bare auto-bridge hits a mixed Swift 5/6 thunk-coalescing crash (swiftlang/swift#81846) fixed in 6.3

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
<description>'Diagnose data races, convert callback-based code to async/await, implement actor isolation patterns, resolve Sendable conformance issues, and guide Swift 6 migration. Use when developers mention: (1) Swift Concurrency, async/await, actors, or tasks, (2) "use Swift Concurrency" or "modern concurrency patterns", (3) migrating to Swift 6, (4) data races or thread safety issues, (5) refactoring closures to async/await, (6) @MainActor, Sendable, or actor isolation, (7) concurrent code architecture or performance optimization, (8) concurrency-related linter warnings (SwiftLint or similar; e.g. async_without_await, Sendable/actor isolation/MainActor lint).'</description>
<location>global</location>
</skill>

<skill>
<name>swift-testing-expert</name>
<description>'Expert guidance for Swift Testing: test structure, #expect/#require macros, traits and tags, parameterized tests, test plans, parallel execution, async waiting patterns, and XCTest migration. Use when writing new Swift tests, modernizing XCTest suites, debugging flaky tests, or improving test quality and maintainability in Apple-platform or Swift server projects.'</description>
<location>global</location>
</skill>

</available_skills>
<!-- SKILLS_TABLE_END -->

</skills_system>
