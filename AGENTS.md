# LiveKit Swift SDK

## Commands

The Swift package supports multiple platforms:
- macOS (`macOS`)
- macOS Catalyst (`macOS,variant=Mac Catalyst`)
- iOS (`iOS Simulator`)
- visionOS (`visionOS Simulator`)
- tvOS (`tvOS Simulator`)

Build instructions:
- Building the package: `xcodebuild build -scheme LiveKit -destination <your-destination>`
- Tests require LiveKit server to be running locally: `livekit-server --dev`, that can be installed with `brew install livekit` if not found 
- Running tests: `xcodebuild test -scheme LiveKit -only-testing LiveKitCoreTests -destination <your-destination>`
- Core functionality that does not involve any platform-specific code (`#if os`) can be simply built and tested on macOS: `xcodebuild build -scheme LiveKit -destination 'platform=macOS'`
- Platform-specific parts can be built using Simulators, to list Simulators use `xcrun simctl list devices`

## Architecture

## Testing

## Using Swift

### Language version

- Supported Xcode versions are the current one, minus two major versions (including beta)
- `Package.swift` and `.swift-version` declares the **oldest** supported version e.g. `swift-tools-version:x.x`, so that linting tools, etc. can maintain backwards compatibility
- There might be another `Package@swift-x.x.swift` introduced for newer versions, make sure all the manifests are in sync when performing package-level changes, such as adding dependencies
- New code should use the latest known stable Swift version
- Some constructs may not be available in earlier versions, thus requiring `#if swift` or `#if compiler` directive, e.g.

```swift
#if swift(>=6.0)
public nonisolated(unsafe) static let shared = AudioManager()
#else
public static let shared = AudioManager()
#endif
```

- Changes may be required between Swift 5 and 6 to support strict concurrency

### Concurrency and State

- The SDK should use Swift 6 concurrency primitives by default and leverage data-race safety
- Most of the SDK features (excluding single UI-level building blocks like `VideoView`) require asynchronous work to be performed on **background** threads, from Swift down to Obj-C++
- The choice of synchronization primitives will depend on API requirements (sync/async)
- Many internal entities can communicate via `async` calls and/or `AsyncSequence`/`AsyncStream` (message passing) and use `actor` for synchronization
- Network connections and other asynchronous sources can often be modeled as `AsyncSequence`
- Delegates and closures should only be used to bridge to existing public APIs such as `RoomDelegate`
- `actor` can use `nonisolated` entry points to integrate with existing or `public` code
- A common pattern is to use an internal "event loop" to process incoming data in FIFO order
- If a synchronous/`nonisolated` API (getters) is a must, use `StateSync` pattern that requires internal locking and `@unchecked Sendable` annotations inside `Support/Sync`
- Lock contention must be minimized e.g. by grouping synchronous reads and writes under one `state.mutate { ... }` call
- Make sure that atomic changes on the `StateSync` do not change the behavior of the program
- Adding `@unchecked Sendable` to a class requires reviewing its internals for synchronization
- Avoid using `@MainActor` for synchronization of static members etc. at any cost for non-UI components
- Long-running `Task` requires cooperative cancellation and explicit lifecycle to avoid memory leaks e.g. via `AsyncSequence.subscribe`
- Use existing `async` primitives defined in `Support/Async` and `Support/Schedulers` if order of operations must be enforced
- Prefer `swift-async-algorithms` over `Combine` for Rx-style operators

### Error handling

- While designing a new API consider defensive programming techniques first (retry, backoff, graceful failure) if possible for recoverable errors
- For non-recoverable errors, propagate them with `throws` using existing/new instance of `LiveKitError` with proper type/code
- Obvious invalid states (e.g. empty optional, invalid transition) should be anticipated at compile time if possible by leveraging lock patterns, algebraic data types, typestates, etc.

### Coding style

- Consistency across features and concepts is more important for long-term maintainability than using latest syntactic sugar
- Run `swiftlint` to lint, see `.swiftlint` for configuration
- **Do not** introduce new warnings while adding/refactoring code
- If there is `// swiftlint:disable` comment in the legacy files that are touched, try to remove that by refactoring, usually breaking into smaller pieces
- Deprecation warnings are generally allowed and intended in the public APIs, do not try to fix them
- `// Code comments` should be used sparingly, always prefer better naming/structuring the code into variables, functions
- Do not add trivial comments based on the prompts `// Here is the change`
- `/// Docstrings` should be added for **every** public API and use Swift markdown syntax (`- Note`, `- Warning`, `-SeeAlso`, etc.)
- Add short, high-level code examples for new APIs if possible to the corresponding entry point (usually a `class` e.g. `Room`)
- `Loggable` logs should use `.debug` level by default, add `.warning` or `.error` only to surface them to the consumers
- Inconsistencies like `_privateFields` should be removed when touching the surrounding code

### SwiftUI

- If an object conforms to `ObservableObject` make sure the changes are published
- It may require manually calling `objectWillChangePublisher` combined with `StateSync`

### Obj-C support

- As for now, **public** APIs should support Obj-C by default with `@objc` annotations at the highest possible level (`class`)
- Adding the support may require some upfront design decisions and restricts the Swift types that can be used, e.g. enums with associated values, structs, async primitives, delegates
- Internal and private APIs should **not** support Obj-C unless absolutely required by the public API surface and leverage Swift powerful type system instead
- If introducing Obj-C leads to awkward or less type-safe patterns, consider wrapping Swift in additional layer(s) and then expose as `@objc` instead of sacrificing Swift APIs
