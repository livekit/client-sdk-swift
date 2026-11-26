---
"client-sdk-swift": patch
---

A `LeaveRequest` with `action == RECONNECT` is no longer downgraded to a resume. The leave handler stored the requested mode and then tore signalling down, and that teardown is what schedules the reconnect — which overwrote the stored mode with its own unset default, so the client resumed a participant the server had already dropped
