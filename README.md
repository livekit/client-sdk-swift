# Swift Multiplatform (iOS and macOS) SDK for LiveKit

This is the official LiveKit Swift client SDK. 

Together with LiveKit [server](https://github.com/livekit/livekit-server), you can easily add real-time video/audio/data capabilities to your iOS or macOS apps.

<insert gif/image here />

## Features

## Installation

### Requirements

### Swift Package Manager

#### XCode
Go to Project Settings -> Swift Packages.
Add a new package and enter: `https://github.com/livekit/client-sdk-swift`

#### Package.swift
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

## Quickstart

### Something Simple with SwiftUI

### Something Simple with UIKit
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

### Something More Advanced

## Documentation

LiveKit docs, guides and sample apps are available at [https://docs.livekit.io](https://docs.livekit.io). We also have minimal examples to get you started with Swift, UIKit, or Objective-C here 👉 [Starter Kits](https://github.com/livekit/client-example-collection-swift).

### Sample Apps

- A Zoom-style meeting client for iOS and macOS: [Meet for iOS/macOS](https://github.com/livekit/client-example-swift).

## Community and Support
There are a few places to keep up with LiveKit updates and get help or advice on issues:

- [Join the LiveKit Slack](https://livekit.io/join-slack), where community members and the LiveKit core team hang out every day.
- [Follow @livekitted](https://twitter.com/livekitted) on Twitter
- Read and sub to the [LiveKit Blog](https://blog.livekit.io)

## Contributing
We welcome your contributions toward improving LiveKit! Please join us on Slack to discuss your ideas and/or PRs.
