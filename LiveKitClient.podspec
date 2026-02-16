Pod::Spec.new do |spec|
  spec.name = "LiveKitClient"
  spec.version = "2.12.0"
  spec.summary = "LiveKit Swift Client SDK. Easily build live audio or video experiences into your mobile app, game or website."
  spec.homepage = "https://github.com/livekit/client-sdk-swift"
  spec.license = {:type => "Apache 2.0", :file => "LICENSE"}
  spec.author = "LiveKit"

  spec.ios.deployment_target = "13.0"
  spec.osx.deployment_target = "10.15"

  spec.swift_versions = ["5.9"]
  spec.source = {:git => "https://github.com/livekit/client-sdk-swift.git", :tag => spec.version.to_s}

  spec.source_files = "Sources/**/*"

  spec.dependency("LiveKitWebRTC", "= 137.7151.12")
  spec.dependency("LiveKitUniFFI", "= 0.0.5")
  spec.dependency("SwiftProtobuf")
  spec.dependency("DequeModule", "= 1.1.4")
  spec.dependency("OrderedCollections", " = 1.1.4")

  spec.resource_bundles = {"Privacy" => ["Sources/LiveKit/PrivacyInfo.xcprivacy"]}

  xcode_output = `xcodebuild -version`.strip
  major_version = xcode_output =~ /Xcode\s+(\d+)/ ? $1.to_i : 15

  spec.pod_target_xcconfig = {
    "OTHER_SWIFT_FLAGS" => major_version >=15  ?
      "-enable-experimental-feature AccessLevelOnImport" : ""
  }
end
