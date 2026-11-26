---
"client-sdk-swift": minor
---

Default to a single peer connection, so the publisher offer rides with the JOIN request. Keep the negotiated signal path across a full reconnect, and scope it to the endpoint it was negotiated with so a fresh connect or a region failover is not pinned to the legacy path by an earlier server
