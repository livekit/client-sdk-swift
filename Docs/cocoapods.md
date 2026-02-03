# CocoaPods Installation

> [!IMPORTANT]
>
> **CocoaPods support is deprecated**. The main [CocoaPods trunk](https://blog.cocoapods.org/CocoaPods-Specs-Repo/) repo as well as LiveKit [podspecs](https://github.com/livekit/podspecs) repo will become read-only and stop receiving updates starting in **2027**. It is strongly recommended to migrate to Swift Package Manager to ensure access to the latest features and security updates.

To install LiveKit using CocoaPods, add the LiveKit podspec source to your
Podfile in addition to adding the pod:

```ruby
source "https://cdn.cocoapods.org/"
source "https://github.com/livekit/podspecs.git" # <-

platform :ios, "18.0"

target "YourApp" do
    pod "LiveKitClient", "~> 2.2.0"

    # Other dependencies...
end
```

The LiveKit source is necessary as some of this library's dependencies
no longer officially support Cocoapods; the LiveKit source defines
podspecs for such dependencies.

## Platform support

Currently, only iOS and macOS are supported through Cocoapods. To use
LiveKit in a tvOS or visionOS app, please install using SPM.
