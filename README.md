<!--BEGIN_BANNER_IMAGE-->

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="/.github/banner_dark.png">
  <source media="(prefers-color-scheme: light)" srcset="/.github/banner_light.png">
  <img style="width:100%;" alt="The LiveKit icon, the name of the repository and some sample code in the background." src="https://raw.githubusercontent.com/livekit/client-sdk-swift/main/.github/banner_light.png">
</picture>

<!--END_BANNER_IMAGE-->

# iOS/macOS Swift SDK for LiveKit

<!--BEGIN_DESCRIPTION-->
Use this SDK to add realtime video, audio and data features to your Swift app. By connecting to <a href="https://livekit.io/">LiveKit</a> Cloud or a self-hosted server, you can quickly build applications such as multi-modal AI, live streaming, or video calls with just a few lines of code.
<!--END_DESCRIPTION-->

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Flivekit%2Fclient-sdk-swift%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/livekit/client-sdk-swift)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Flivekit%2Fclient-sdk-swift%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/livekit/client-sdk-swift)

## Docs & Example app

> [!NOTE]
> Version 2 of the Swift SDK contains breaking changes from Version 1.
> Read the [migration guide](https://docs.livekit.io/guides/migrate-from-v1/) for a detailed overview of what has changed.

Docs and guides are at [https://docs.livekit.io](https://docs.livekit.io).

There is full source code of a [iOS/macOS Swift UI Example App](https://github.com/livekit/client-example-swift).

For minimal examples view this repo 👉 [Swift SDK Examples](https://github.com/livekit/client-example-collection-swift)

## Installation

LiveKit for Swift is available as a Swift Package.

### Package.swift

Add the dependency and also to your target

```swift title="Package.swift"
let package = Package(
  ...
  dependencies: [
    .package(name: "LiveKit", url: "https://github.com/livekit/client-sdk-swift.git", .upToNextMajor("2.12.1")),
  ],
  targets: [
    .target(
      name: "MyApp",
      dependencies: ["LiveKit"]
    )
  ]
}
```

### XCode

Go to Project Settings -> Swift Packages.

Add a new package and enter: `https://github.com/livekit/client-sdk-swift`

### CocoaPods

> [!IMPORTANT]
>
> **CocoaPods support is deprecated**. The main [CocoaPods trunk](https://blog.cocoapods.org/CocoaPods-Specs-Repo/) repo as well as LiveKit [podspecs](https://github.com/livekit/podspecs) repo will become read-only and stop receiving updates starting in **2027**. It is strongly recommended to migrate to Swift Package Manager to ensure access to the latest features and security updates.

For installation using CocoaPods, please refer to this [guide](./Docs/cocoapods.md).

## iOS Usage

LiveKit provides an UIKit based `VideoView` class that renders video tracks. Subscribed audio tracks are automatically played.

```swift
import LiveKit
import UIKit

class RoomViewController: UIViewController {

    lazy var room = Room(delegate: self)

    lazy var remoteVideoView: VideoView = {
        let videoView = VideoView()
        view.addSubview(videoView)
        // Additional initialization ...
        return videoView
    }()

    lazy var localVideoView: VideoView = {
        let videoView = VideoView()
        view.addSubview(videoView)
        // Additional initialization ...
        return videoView
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        let url = "ws://your_host"
        let token = "your_jwt_token"

        Task {
            do {
                try await room.connect(url: url, token: token)
                // Connection successful...

                // Publishing camera & mic...
                try await room.localParticipant.setCamera(enabled: true)
                try await room.localParticipant.setMicrophone(enabled: true)
            } catch {
                // Failed to connect
            }
        }
    }
}

extension RoomViewController: RoomDelegate {

    func room(_: Room, participant _: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        guard let track = publication.track as? VideoTrack else { return }
        DispatchQueue.main.async {
            self.localVideoView.track = track
        }
    }

    func room(_: Room, participant _: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard let track = publication.track as? VideoTrack else { return }
        DispatchQueue.main.async {
            self.remoteVideoView.track = track
        }
    }
}
```

### Screen Sharing

See [iOS Screen Sharing instructions](Docs/ios-screen-sharing.md).

## Integration Notes

### Submitting to the App Store, DSYMs

`LiveKitWebRTC.xcframework` binary framework, which is the main dependency of the SDK, does not contain DSYMs. Submitting the app to the App Store will result in a following warning:

```
The archive did not include a dSYM for the LiveKitWebRTC.framework with the UUIDs [...]. Ensure that the archive's dSYM folder includes a DWARF file for LiveKitWebRTC.framework with the expected UUIDs.
```

It will **not prevent** the app from being submitted to the App Store or passing the review process.

If you are building a customized version of the [LiveKitWebRTC](https://github.com/webrtc-sdk/webrtc), you can use the [build script](https://github.com/webrtc-sdk/webrtc-build/blob/main/build/apple/xcframework.sh) in `DEBUG` mode to generate them locally.

### Thread safety

Since `VideoView` is a UI component, all operations (read/write properties etc) must be performed from the `main` thread.

Other core classes can be accessed from any thread.

Delegates will be called on the SDK's internal thread.
Make sure any access to your app's UI elements are from the main thread, for example by using `@MainActor` or `DispatchQueue.main.async`.

### Swift 6

LiveKit is currently compiled using Swift 6.0 with full support for strict concurrency. Apps compiled in Swift 6 language mode will not need to use `@preconcurrency` or `@unchecked Sendable` to access LiveKit classes.

### Memory management

It is recommended to use **weak var** when storing references to objects created and managed by the SDK, such as `Participant`, `TrackPublication` etc. These objects are invalid when the `Room` disconnects, and will be released by the SDK. Holding strong reference to these objects will prevent releasing `Room` and other internal objects.

`VideoView.track` property does not hold strong reference, so it's not required to set it to `nil`.

### AudioSession management

LiveKit will automatically manage the underlying `AVAudioSession` while connected. By default, the session is set to the `.playback` category. When a local track is published, it switches to `.playAndRecord`. In general, it picks sane defaults and does the right thing.

If you'd like to configure `AVAudioSession` yourself, disable the SDK's automatic audio session handling:
```swift
AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
```

- `AVAudioSession` must be configured and activated with category `.playAndRecord` and mode `.voiceChat` or `.videoChat` before enabling/publishing the microphone (so the audio engine can start).

To get specific timings of the audio engine lifecycle, you can provide your own `AudioEngineObserver` chain with `AudioManager.shared.set(engineObservers:)`.

See the default `AudioSessionEngineObserver` for an example of how an `AudioEngineObserver` can configure the audio session.

- If you want to reduce mic publish latency, you can pre-warm the audio engine with `AudioManager.shared.setRecordingAlwaysPreparedMode(true)`.
- For additional audio-related information, see the [Audio guide](./Docs/audio.md).

### Integration with CallKit

When integrating with CallKit, proper timing and coordination between `AVAudioSession` and the SDK’s audio engine is crucial.

1. Disable the SDK’s automatic `AVAudioSession` configuration, and prevent the audio engine from starting outside CallKit’s `provider(_:didActivate:)` and `provider(_:didDeactivate:)` window.

```swift
// As early as possible, before connecting to a Room.
AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
try AudioManager.shared.setEngineAvailability(.none)
```

2. Coordinate audio engine availability with CallKit in your `CXProviderDelegate` implementation:

```swift
func provider(_: CXProvider, didActivate session: AVAudioSession) {
  do {
    try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers])
    try AudioManager.shared.setEngineAvailability(.default)
  } catch {
    // Error
  }
}

func provider(_: CXProvider, didDeactivate _: AVAudioSession) {
  do {
    try AudioManager.shared.setEngineAvailability(.none)
  } catch {
    // Error
  }
}
```

* See our [CallKit example](https://github.com/livekit-examples/swift-example-collection/tree/main/callkit) for full details.
* For additional audio-related information, see the [Audio guide](./Docs/audio.md).

### iOS Simulator limitations

- Publishing the camera track is not supported by iOS Simulator.

### ScrollView performance

It is recommended to turn off rendering of `VideoView`s that scroll off the screen and isn't visible by setting `false` to `isEnabled` property and `true` when it will re-appear to save CPU resources.

`UICollectionViewDelegate`'s `willDisplay` / `didEndDisplaying` has been reported to be unreliable for this purpose. Specifically, in some iOS versions `didEndDisplaying` could get invoked even when the cell is visible.

The following is an alternative method to using `willDisplay` / `didEndDisplaying` :

```swift
// 1. define a weak-reference set for all cells
private var allCells = NSHashTable<ParticipantCell>.weakObjects()
```

```swift
// in UICollectionViewDataSource...
public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {

    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ParticipantCell.reuseIdentifier, for: indexPath)

    if let cell = cell as? ParticipantCell {
        // 2. keep weak reference to the cell
        allCells.add(cell)

        // configure cell etc...
    }

    return cell
}
```

```swift
// 3. define a func to re-compute and update isEnabled property for cells that visibility changed
func reComputeVideoViewEnabled() {

    let visibleCells = collectionView.visibleCells.compactMap { $0 as? ParticipantCell }
    let offScreenCells = allCells.allObjects.filter { !visibleCells.contains($0) }

    for cell in visibleCells.filter({ !$0.videoView.isEnabled }) {
        print("enabling cell#\(cell.hashValue)")
        cell.videoView.isEnabled = true
    }

    for cell in offScreenCells.filter({ $0.videoView.isEnabled }) {
        print("disabling cell#\(cell.hashValue)")
        cell.videoView.isEnabled = false
    }
}
```

```swift
// 4. set a timer to invoke the func
self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true, block: { [weak self] _ in
    self?.reComputeVideoViewEnabled()
})

// alternatively, you can call `reComputeVideoViewEnabled` whenever cell visibility changes (such as scrollViewDidScroll(_:)),
// but this will be harder to track all cases such as cell reload etc.
```

For the full example, see 👉 [UIKit Minimal Example](https://github.com/livekit/client-example-collection-swift/tree/main/uikit-minimal)

# Frequently asked questions

### How to adjust the log level?

The SDK will write to `OSLog` by default (`io.livekit.*`) with a minimum log level of `info`. Logs can be filtered by level, category, etc. using Xcode console.

- To adjust the log level, call `LiveKitSDK.setLogLevel(_:)`
- To set a custom logger (e.g. to pass to a custom logging system), call `LiveKitSDK.setLogger(_:)`
- To disable logging completely, call `LiveKitSDK.disableLogging()`

All methods must be called before any other logging is done, e.g. in the `App.init()` or `AppDelegate/SceneDelegate`.

Alternatively, you can subclass `OSLogger` and override the `log(...)` method to capture e.g. warning and error logs.

### How to publish camera in 60 FPS?

- Create a `LocalVideoTrack` by calling `LocalVideoTrack.createCameraTrack(options: CameraCaptureOptions(fps: 60))`.
- Publish with `LocalParticipant.publish(videoTrack: track, publishOptions: VideoPublishOptions(encoding: VideoEncoding(maxFps: 60)))`.

# Known issues

### Avoid crashes on macOS Catalina

If your app is targeting macOS Catalina, make sure to do the following to avoid crash (ReplayKit not found):

1. Explicitly add "ReplayKit.framework" to the Build Phases > Link Binary with Libraries section
2. Set it to Optional

<img width="752" alt="replykit" src="https://user-images.githubusercontent.com/548776/201249295-51d9cb76-32bd-4b10-9f4c-02951d1b2edb.png">

- I am not sure why this is required for ReplayKit at the moment.
- If you are targeting macOS 11.0+, this is not required.

# Getting help / Contributing

Please join us on [Slack](https://livekit.io/join-slack) to get help from our devs / community members. We welcome your contributions(PRs) and details can be discussed there.

<!--BEGIN_REPO_NAV-->
<br/><table>
<thead><tr><th colspan="2">LiveKit Ecosystem</th></tr></thead>
<tbody>
<tr><td>LiveKit SDKs</td><td><a href="https://github.com/livekit/client-sdk-js">Browser</a> · <b>iOS/macOS/visionOS</b> · <a href="https://github.com/livekit/client-sdk-android">Android</a> · <a href="https://github.com/livekit/client-sdk-flutter">Flutter</a> · <a href="https://github.com/livekit/client-sdk-react-native">React Native</a> · <a href="https://github.com/livekit/rust-sdks">Rust</a> · <a href="https://github.com/livekit/node-sdks">Node.js</a> · <a href="https://github.com/livekit/python-sdks">Python</a> · <a href="https://github.com/livekit/client-sdk-unity">Unity</a> · <a href="https://github.com/livekit/client-sdk-unity-web">Unity (WebGL)</a> · <a href="https://github.com/livekit/client-sdk-esp32">ESP32</a></td></tr><tr></tr>
<tr><td>Server APIs</td><td><a href="https://github.com/livekit/node-sdks">Node.js</a> · <a href="https://github.com/livekit/server-sdk-go">Golang</a> · <a href="https://github.com/livekit/server-sdk-ruby">Ruby</a> · <a href="https://github.com/livekit/server-sdk-kotlin">Java/Kotlin</a> · <a href="https://github.com/livekit/python-sdks">Python</a> · <a href="https://github.com/livekit/rust-sdks">Rust</a> · <a href="https://github.com/agence104/livekit-server-sdk-php">PHP (community)</a> · <a href="https://github.com/pabloFuente/livekit-server-sdk-dotnet">.NET (community)</a></td></tr><tr></tr>
<tr><td>UI Components</td><td><a href="https://github.com/livekit/components-js">React</a> · <a href="https://github.com/livekit/components-android">Android Compose</a> · <a href="https://github.com/livekit/components-swift">SwiftUI</a> · <a href="https://github.com/livekit/components-flutter">Flutter</a></td></tr><tr></tr>
<tr><td>Agents Frameworks</td><td><a href="https://github.com/livekit/agents">Python</a> · <a href="https://github.com/livekit/agents-js">Node.js</a> · <a href="https://github.com/livekit/agent-playground">Playground</a></td></tr><tr></tr>
<tr><td>Services</td><td><a href="https://github.com/livekit/livekit">LiveKit server</a> · <a href="https://github.com/livekit/egress">Egress</a> · <a href="https://github.com/livekit/ingress">Ingress</a> · <a href="https://github.com/livekit/sip">SIP</a></td></tr><tr></tr>
<tr><td>Resources</td><td><a href="https://docs.livekit.io">Docs</a> · <a href="https://github.com/livekit-examples">Example apps</a> · <a href="https://livekit.io/cloud">Cloud</a> · <a href="https://docs.livekit.io/home/self-hosting/deployment">Self-hosting</a> · <a href="https://github.com/livekit/livekit-cli">CLI</a></td></tr>
</tbody>
</table>
<!--END_REPO_NAV-->
