# Audio related

## Disabling automatic `AVAudioSession` configuration

By default, the SDK automatically configures the `AVAudioSession`. However, this can interfere with your own configuration or with frameworks like CallKit that configure the AVAudioSession automatically. In such cases, you can disable automatic configuration by the SDK.

```swift
AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
```

## Disabling Voice Processing

Apple's voice processing is enabled by default, such as echo cancellation and auto-gain control.

If your app doesn't require voice processing at all, you can disable it entirely:

```swift
AudioManager.shared.isVoiceProcessingEnabled = false
```

This method re-creates the internal `AVAudioEngine` with/without voice processing enabled. It is valid to toggle these settings at run-time but can cause audio glitches, so it is recommended to set it once before connecting to a Room.

If your app requires toggling voice processing at run-time, it is recommended to use:

```swift
AudioManager.shared.isVoiceProcessingBypassed = false
```

This method calls `AVAudioEngine`'s [isVoiceProcessingBypassed](https://developer.apple.com/documentation/avfaudio/avaudioinputnode/isvoiceprocessingbypassed) and works seamlessly at run-time.
