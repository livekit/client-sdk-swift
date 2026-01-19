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
- `Package.swift` and `.swift-version` declares the **oldest** supported version, so that linting tools, etc. can maintain backwards compatibility
- There might be another `Package@swift-x.x.swift` introduced for newer versions, make sure all the manifests are in sync when performing package-level changes
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

### State management

### Concurrency

### Coding style
