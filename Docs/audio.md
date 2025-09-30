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
## Capturing Audio Buffers

The SDK supports capturing custom audio buffers (`AVAudioPCMBuffer`) instead of or in addition to microphone input.

### Capturing Audio Buffers with Microphone

To capture custom audio buffers while still using the microphone:

1. Enable the microphone:
   ```swift
   room.localParticipant.setMicrophone(enabled: true)
   ```

2. Repeatedly call the capture method with your audio buffers:
   ```swift
   AudioManager.shared.mixer.capture(appAudio: yourAudioBuffer)
   ```

### Capturing Audio Buffers Without Device Access (Manual Mode)

For applications that need to provide audio without accessing the device's microphone:

1. Enable manual rendering mode:
   ```swift
   try AudioManager.shared.setManualRenderingMode(true)
   ```

2. Enable the microphone track (this won't access the physical microphone in manual mode):
   ```swift
   room.localParticipant.setMicrophone(enabled: true)
   ```

3. Provide audio buffers continuously:
   ```swift
   AudioManager.shared.mixer.capture(appAudio: yourAudioBuffer)
   ```

> **NOTE**: When manual rendering mode is enabled, the audio engine doesn't access any audio devices. This means remote audio will not be played automatically and you must handle audio playback yourself.

> **NOTE**: Audio format will be automatically converted so you don't need to handle this yourself.

### Volume Control

You can adjust the volume levels for different audio sources:

- **Microphone volume**: `AudioManager.shared.mixer.micVolume`
- **Custom audio buffer volume**: `AudioManager.shared.mixer.appVolume`

Both properties accept values from `0.0` (muted) to `1.0` (full volume).
