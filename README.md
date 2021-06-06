# iOS Swift SDK for LiveKit

Official Client SDK for [LiveKit](https://github.com/livekit/livekit-server). Easily add video & audio capabilities to your iOS apps.

## Docs

Docs and guides at [https://docs.livekit.io](https://docs.livekit.io)

## Installation

LiveKit for iOS is available as a Swift Package.

### Package.swift

Add the dependency and also to your target

```swift title="Package.swift"
let package = Package(
  ...
  dependencies: [
    .package(name: "LiveKit", url: "https://github.com/livekit/client-sdk-ios.git", .upToNextMajor("version")),
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

Add a new package and enter: `https://github.com/livekit/client-sdk-ios`

## Usage

LiveKit provides an UIKit based `VideoView` class that renders video tracks. Subscribed audio tracks are automatically played.

```swift
import LiveKit
import UIKit

class RoomViewController: UIViewController {
    var room: Room?
    var remoteVideo: VideoView?
    var localVideo: VideoView?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        let url: String = "ws://your_host"
        let token: String = "your_jwt_token"

        room = LiveKit.connect(options: ConnectOptions(url: url, token: token), delegate: self)
    }

    func attachVideo(track: VideoTrack, participant: Participant) {
      let videoView = VideoView(frame: .zero)
      // find destination view
      ...
      target.addSubview(videoView)
      track.addRenderer(videoView.renderer)
    }
}

extension RoomViewController: RoomDelegate {
    func didConnect(room: Room) {
        guard let localParticipant = room.localParticipant else {
            return
        }

        // perform work in the background, to not block WebRTC threads
        DispatchQueue.global(qos: .background).async {
          do {
              let videoTrack = try LocalVideoTrack.createTrack(name: "localVideo")
              _ = localParticipant.publishVideoTrack(track: videoTrack)
              let audioTrack = LocalAudioTrack.createTrack(name: "localAudio")
              _ = localParticipant.publishAudioTrack(track: audioTrack)
          } catch {
              // error publishing
          }
        }

        // attach video view
        attachVideo(videoTrack, localParticipant)
    }

    func didSubscribe(track: Track, publication _: RemoteTrackPublication, participant _: RemoteParticipant) {
        guard let videoTrack = track as? VideoTrack else {
          return
        }
        DispatchQueue.main.async {
            attachVideo(videoTrack, participant)
        }
    }
}
```
