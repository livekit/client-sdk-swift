# iOS/macOS Swift SDK for LiveKit

Official Client SDK for [LiveKit](https://github.com/livekit/livekit-server).
Easily add video & audio capabilities to your iOS/macOS apps.

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
    .package(name: "LiveKit", url: "https://github.com/livekit/client-sdk-swift.git", .upToNextMajor("0.9.5")),
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

# iOS Simulator limitations

- Currently, `VideoView` does not render on iOS simulator.
- Publishing the camera track is not supported by iOS simulator.

# ScrollView performance

It is recommended to turn off rendering of `VideoView`s that scroll off the screen and isn't visible by setting `false` to `isEnabled` property and `true` when it will re-appear to save CPU resources.

The following is an example for `UICollectionView` (UIKit), implement `UICollectionViewDelegate` and use `willDisplay` / `didEndDisplaying` to update the `isEnabled` property.

```swift
extension YourViewController: UICollectionViewDelegate {

   func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let yourCell = cell as? YourCell else { return }
        yourCell.videoView.isEnabled = true
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let yourCell = cell as? YourCell else { return }
        yourCell.videoView.isEnabled = false
    }
}
```

# Getting help / Contributing

Please join us on [Slack](https://join.slack.com/t/livekit-users/shared_invite/zt-rrdy5abr-5pZ1wW8pXEkiQxBzFiXPUg) to get help from our [devs](https://github.com/orgs/livekit/teams/devs/members) / community members. We welcome your contributions(PRs) and details can be discussed there.
