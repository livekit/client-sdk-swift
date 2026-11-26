---
"client-sdk-swift": minor
---

Reconnect attempts follow each other sooner at the start. With the defaults the delays are now 0.3, 1.2, 2.7 and 4.8 s, then 7 s, less a random part of up to 10 percent. Before, the second delay was already 3.4 s.
