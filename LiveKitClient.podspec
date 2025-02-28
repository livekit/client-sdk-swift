Pod::Spec.new do |spec|
  spec.name = "LiveKitClient"
  spec.version = "2.2.1"
  spec.summary = "LiveKit Swift Client SDK. Easily build live audio or video experiences into your mobile app, game or website."
  spec.homepage = "https://github.com/livekit/client-sdk-swift"
  spec.license = {:type => "Apache 2.0", :file => "LICENSE"}
  spec.author = "LiveKit"

  spec.ios.deployment_target = "13.0"
  spec.osx.deployment_target = "10.15"
  spec.tvos.deployment_target = "17.0"
  spec.visionos.deployment_target = "1.0"

  spec.swift_versions = ["5.7"]
  spec.source = {:git => "https://github.com/livekit/client-sdk-swift.git", :tag => "2.2.1"}

  spec.source_files = "Sources/**/*"

  spec.dependency("LiveKitWebRTC", "= 125.6422.19")
  spec.dependency("SwiftProtobuf")
  spec.dependency("Logging")

  spec.resource_bundles = {"Privacy" => ["Sources/LiveKit/PrivacyInfo.xcprivacy"]}

  # Add the following lines to enable the experimental feature
  spec.pod_target_xcconfig = {
    'OTHER_SWIFT_FLAGS' => '-enable-experimental-feature AccessLevelOnImport'
  }
end
