---
"client-sdk-swift": minor
---

Data streams: cancelling a read closes the stream. The cancelled read throws CancellationError, and later reads throw StreamError.alreadyClosed
