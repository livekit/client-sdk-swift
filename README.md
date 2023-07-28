<!--BEGIN_BANNER_IMAGE-->
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="/.github/banner_dark.png">
    <source media="(prefers-color-scheme: light)" srcset="/.github/banner_light.png">
    <img style="width:100%;" alt="The LiveKit icon, the name of the repository and some sample code in the background." src="/.github/banner_light.png">
  </picture>
  <!--END_BANNER_IMAGE-->

# iOS/macOS Swift SDK for LiveKit

<!--BEGIN_DESCRIPTION-->Use this SDK to add real-time video, audio and data features to your Swift app. By connecting to a self- or cloud-hosted <a href="https://livekit.io/">LiveKit</a> server, you can quickly build applications like interactive live streaming or video calls with just a few lines of code.<!--END_DESCRIPTION-->

## Docs & Example app

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
    .package(name: "LiveKit", url: "https://github.com/livekit/client-sdk-swift.git", .upToNextMajor("1.0.0")),
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
        // additional initialization ...
        return videoView
    }()

    lazy var localVideoView: VideoView = {
        let videoView = VideoView()
        view.addSubview(videoView)
        // additional initialization ...
        return videoView
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        let url: String = "ws://your_host"
        let token: String = "your_jwt_token"

        room.connect(url, token).then { room in

            // Publish camera & mic
            room.localParticipant?.setCamera(enabled: true)
            room.localParticipant?.setMicrophone(enabled: true)

        }.catch { error in
            // failed to connect
        }
    }
}

extension RoomViewController: RoomDelegate {

    func room(_ room: Room, localParticipant: LocalParticipant, didPublish publication: LocalTrackPublication) {
        guard let track = publication?.track as? VideoTrack else {
            return
        }
        DispatchQueue.main.async {
            localVideoView.track = track
        }
    }

    func room(_ room: Room, participant: RemoteParticipant, didSubscribe publication: RemoteTrackPublication, track: Track) {
        guard let track = track as? VideoTrack else {
          return
        }
        DispatchQueue.main.async {
            remoteVideoView.track = track
        }
    }
}
```

### Screen Sharing

See [iOS Screen Sharing instructions](https://github.com/livekit/client-sdk-swift/wiki/iOS-Screen-Sharing).

## Integration Notes

### Thread safety

Since `VideoView` is a UI component, all operations (read/write properties etc) must be performed from the `main` thread.

Other core classes can be accessed from any thread.

Delegates will be called on the SDK's internal thread.
Make sure any access to the UI is within the main thread, for example by using `DispatchQueue.main.async`.

### Memory management

It is recommended to use **weak var** when storing references to objects created and managed by the SDK, such as `Participant`, `TrackPublication` etc. These objects are invalid when the `Room` disconnects, and will be released by the SDK. Holding strong reference to these objects will prevent releasing `Room` and other internal objects.

`VideoView.track` property does not hold strong reference, so it's not required to set it to `nil`.

### AudioSession management

LiveKit will automatically manage the underlying `AVAudioSession` while connected. The session will be set to `playback` category by default. When a local stream is published, it'll be switched to
`playAndRecord`. In general, it'll pick sane defaults and do the right thing.

However, if you'd like to customize this behavior, you would override `AudioManager.customConfigureAudioSessionFunc` to manage the underlying session on your own. See [example here](https://github.com/livekit/client-sdk-swift/blob/1f5959f787805a4b364f228ccfb413c1c4944748/Sources/LiveKit/Track/AudioManager.swift#L153) for the default behavior.

### iOS Simulator limitations

- Currently, `VideoView` will use OpenGL for iOS Simulator.
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

### Mic privacy indicator (orange dot) remains on even after muting audio track

You will need to un-publish the LocalAudioTrack for the indicator to turn off.
More discussion here https://github.com/livekit/client-sdk-swift/issues/140

### How to publish camera in 60 FPS ?

- Create a `LocalVideoTrack` by calling `LocalVideoTrack.createCameraTrack(options: CameraCaptureOptions(fps: 60))`.
- Publish with `LocalParticipant.publishVideoTrack(track: track, publishOptions: VideoPublishOptions(encoding: VideoEncoding(maxFps: 60)))`.

# Known issues

### Avoid crashes on macOS Catalina

If your app is targeting macOS Catalina, make sure to do the following to avoid crash (ReplayKit not found):

1. Explicitly add "ReplayKit.framework" to the Build Phases > Link Binary with Libraries section
2. Set it to Optional

<img width="752" alt="replykit" src="https://user-images.githubusercontent.com/548776/201249295-51d9cb76-32bd-4b10-9f4c-02951d1b2edb.png">

- I am not sure why this is required for ReplayKit at the moment.
- If you are targeting macOS 11.0+, this is not required.

# Getting help / Contributing

Please join us on [Slack](https://join.slack.com/t/livekit-users/shared_invite/zt-rrdy5abr-5pZ1wW8pXEkiQxBzFiXPUg) to get help from our [devs](https://github.com/orgs/livekit/teams/devs/members) / community members. We welcome your contributions(PRs) and details can be discussed there.

<!--BEGIN_REPO_NAV-->
<br/><table>
<thead><tr><th colspan="2">LiveKit Ecosystem</th></tr></thead>
<tbody>
<tr><td>Client SDKs</td><td><a href="https://github.com/livekit/components-js">Components</a> · <a href="https://github.com/livekit/client-sdk-js">JavaScript</a> · <b>iOS/macOS</b> · <a href="https://github.com/livekit/client-sdk-android">Android</a> · <a href="https://github.com/livekit/client-sdk-flutter">Flutter</a> · <a href="https://github.com/livekit/client-sdk-react-native">React Native</a> · <a href="https://github.com/livekit/client-sdk-rust">Rust</a> · <a href="https://github.com/livekit/client-sdk-python">Python</a> · <a href="https://github.com/livekit/client-sdk-unity-web">Unity (web)</a> · <a href="https://github.com/livekit/client-sdk-unity">Unity (beta)</a></td></tr><tr></tr>
<tr><td>Server SDKs</td><td><a href="https://github.com/livekit/server-sdk-js">Node.js</a> · <a href="https://github.com/livekit/server-sdk-go">Golang</a> · <a href="https://github.com/livekit/server-sdk-ruby">Ruby</a> · <a href="https://github.com/livekit/server-sdk-kotlin">Java/Kotlin</a> · <a href="https://github.com/agence104/livekit-server-sdk-php">PHP (community)</a> · <a href="https://github.com/tradablebits/livekit-server-sdk-python">Python (community)</a></td></tr><tr></tr>
<tr><td>Services</td><td><a href="https://github.com/livekit/livekit">Livekit server</a> · <a href="https://github.com/livekit/egress">Egress</a> · <a href="https://github.com/livekit/ingress">Ingress</a></td></tr><tr></tr>
<tr><td>Resources</td><td><a href="https://docs.livekit.io">Docs</a> · <a href="https://github.com/livekit-examples">Example apps</a> · <a href="https://livekit.io/cloud">Cloud</a> · <a href="https://docs.livekit.io/oss/deployment">Self-hosting</a> · <a href="https://github.com/livekit/livekit-cli">CLI</a></td></tr>
</tbody>
</table>
<!--END_REPO_NAV-->
