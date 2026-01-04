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
try AudioManager.shared.setVoiceProcessingEnabled(false)
```

This restarts the internal `AVAudioEngine` to apply the change. It can cause a short audio glitch, so it is recommended to set it once before connecting to a Room. Disabling voice processing also disables muted speaker detection.

If your app requires toggling voice processing at run-time, it is recommended to use:

```swift
AudioManager.shared.isVoiceProcessingBypassed = true
```

Set it back to `false` to re-enable processing. This uses `AVAudioEngine`'s [isVoiceProcessingBypassed](https://developer.apple.com/documentation/avfaudio/avaudioinputnode/isvoiceprocessingbypassed) and works seamlessly at run-time.

## Always-prepared recording mode

If you want to minimize mic publish latency, you can pre-warm the audio engine and keep mic input prepared in a muted state:

```swift
Task.detached {
    try? await AudioManager.shared.setRecordingAlwaysPreparedMode(true)
}
```

Behavior and trade-offs:

- Starts the audio engine configured for mic input in a muted state, so publishing the mic is almost immediate.
- The mic privacy indicator typically stays off while the engine is prepared and muted.
- If `AudioManager.shared.audioSession.isAutomaticConfigurationEnabled` is `true`, the SDK configures the session category to `.playAndRecord`.
- Mic permission is required and the system prompt will appear if not already granted.
- This mode persists across Room lifecycles. The audio engine stays running (muted) even after disconnect, so re-joining and publishing is fast.
- Startup takes a bit longer because voice processing needs to warm up.

Disable it when you no longer need the pre-warmed engine:

```swift
try await AudioManager.shared.setRecordingAlwaysPreparedMode(false)
```

## Microphone mute modes

You can control how mic mute/unmute works:

```swift
try AudioManager.shared.set(microphoneMuteMode: .voiceProcessing)
```

- `.voiceProcessing` (default): Uses `AVAudioEngine.isVoiceProcessingInputMuted`. Fast and does not reconfigure the audio session on mute/unmute. iOS plays a short system sound when muting or unmuting.
- `.restart`: Shuts down the audio engine on mute and restarts it on unmute. This deactivates and reconfigures the audio session, so it is slower and may affect audio session category or volume. No system sound is played. Not recommended for most apps.
- `.inputMixer`: Mutes the input mixer only. The audio engine keeps running and the mic indicator remains on. No system sound is played.

| Mode | iOS beep sound | Mic indicator | Speed |
| --- | --- | --- | --- |
| `.voiceProcessing` | Yes | Turns off | Fast |
| `.restart` | No | Turns off | Slow |
| `.inputMixer` | No | Remains on | Fast |

If you disable automatic audio session configuration (`AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false`), the SDK will not touch the session category. Make sure your app sets `.playAndRecord` before unmuting or publishing the mic.
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
