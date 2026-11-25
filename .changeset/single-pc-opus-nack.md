---
"client-sdk-swift": patch
---

Negotiate Opus NACK on every audio section in single peer connection mode, including send-only offers created before any subscriptions, enabling retransmission of lost audio in both publish and subscribe directions when RED is disabled
