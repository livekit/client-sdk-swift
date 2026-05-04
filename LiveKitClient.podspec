Pod::Spec.new do |spec|
  spec.name = "LiveKitClient"
  spec.version = "2.14.0"
  spec.summary = "LiveKit Swift Client SDK. Easily build live audio or video experiences into your mobile app, game or website."
  spec.homepage = "https://github.com/livekit/client-sdk-swift"
  spec.license = {:type => "Apache 2.0", :file => "LICENSE"}
  spec.author = "LiveKit"

  spec.ios.deployment_target = "13.0"
  spec.osx.deployment_target = "10.15"

  spec.swift_versions = ["5.9"]
  spec.source = {:git => "https://github.com/livekit/client-sdk-swift.git", :tag => spec.version.to_s}

  spec.source_files = "Sources/**/*"

  spec.dependency("LiveKitWebRTC", "= 144.7559.04")
  spec.dependency("LiveKitUniFFI", "= 0.0.6")
  spec.dependency("SwiftProtobuf")

  spec.resource_bundles = {"Privacy" => ["Sources/LiveKit/PrivacyInfo.xcprivacy"]}
end
