
Pod::Spec.new do |spec|

  spec.name         = 'LiveKitClient'
  spec.version      = '1.0.9'
  spec.summary      = 'LiveKit Swift Client SDK. Easily build live audio or video experiences into your mobile app, game or website.'
  spec.homepage     = 'https://github.com/livekit/client-sdk-swift'
  spec.license      = { :type => 'Apache 2.0', :file => 'LICENSE' }
  spec.author       = 'LiveKit'

  spec.ios.deployment_target = '13.0'
  spec.osx.deployment_target = '10.15'

  spec.swift_versions = ['4.2', '5']
  spec.source         = { :git => 'https://github.com/livekit/client-sdk-swift.git', :tag => '1.0.9' }

  spec.source_files   = 'Sources/**/*'

  spec.dependency 'WebRTC-SDK', '~> 104.5112.07'
  spec.dependency 'SwiftProtobuf'
  spec.dependency 'PromisesSwift'
  spec.dependency 'Logging'

  # spec.user_target_xcconfig = { 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64' }
  # spec.pod_target_xcconfig = { 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64' }

end
