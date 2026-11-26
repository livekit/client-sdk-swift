---
"client-sdk-swift": patch
---

Fix RemoteTrackPublication.set(enabled:) and set(preferredFPS:) lowering a subscribed simulcast track to its lowest layer when adaptive stream is off, since the server starts such a subscription at high quality
