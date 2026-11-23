---
"client-sdk-swift": patch
---

Fix local audio not reaching LocalAudioTrack renderers or capturePostProcessingDelegate when captured without a connected Room (startLocalRecording(), manual rendering mode, pre-connect audio buffer). Regressed in 2.13.0
