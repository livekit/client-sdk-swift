# CocoaPods Installation

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
