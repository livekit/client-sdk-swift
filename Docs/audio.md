# Audio related

## Disabling automatic `AVAudioSession` configuration

By default, the SDK automatically configures the `AVAudioSession`. However, this can interfere with your own configuration or with frameworks like CallKit that configure the AVAudioSession automatically. In such cases, you can disable automatic configuration by the SDK.

```swift
AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
```

## Disabling automatic `AVAudioSession` deactivation

> **Note**: If you have already set `isAutomaticConfigurationEnabled = false`, you don't need to worry about this setting since the SDK won't touch the audio session at all.

By default, the SDK deactivates the `AVAudioSession` when both playout and recording are disabled (e.g., after disconnecting from a room). This allows other apps' audio (like Music) to resume.

However, if your app has its own audio features that could be disrupted by deactivating the audio session, you can disable automatic deactivation:

```swift
AudioManager.shared.audioSession.isAutomaticDeactivationEnabled = false
```

When set to `false`, the audio session remains active after the LiveKit call ends, preserving your app's audio state.

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

## Other audio ducking

When using Apple's voice processing APIs, the system may *duck* (lower) *other audio* so the voice chat stays intelligible.

- **What is "other audio"**: Any playback that is *not* the voice-chat stream rendered through the voice processing path (for example, media playback in your app outside the SDK, or audio from other apps).
- **SDK default behavior**: The SDK defaults to minimal ducking with fixed behavior (`isAdvancedDuckingEnabled = false`) and a ducking level of `.min` (when available). This is intended to keep other audio as loud as possible. Stronger or dynamic ducking is opt-in.

The SDK exposes two controls:

- `AudioManager.shared.isAdvancedDuckingEnabled`: When enabled, ducking becomes dynamic based on voice activity from either side of the call (more ducking while someone is speaking, less ducking during silence).
- `AudioManager.shared.duckingLevel`: Controls how much other audio is lowered (`.default`, `.min`, `.mid`, `.max`). `.default` matches Apple's historical fixed ducking amount.

Example:

```swift
// Dynamic ducking based on voice activity (FaceTime / SharePlay-like behavior).
AudioManager.shared.isAdvancedDuckingEnabled = true
// Control the ducking amount (availability depends on the OS).
AudioManager.shared.duckingLevel = .max // maximize voice intelligibility
```

> **NOTE**: These settings apply when the SDK is using Apple's voice processing (default). If you disable voice processing, other-audio ducking does not apply.

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
