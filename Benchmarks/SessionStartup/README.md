# Concurrent Swift Session startup

This measures **concurrent capture/credentials/connection**, not publication reserved in JOIN. Swift PR #1227 does not implement Rust #1050 / JS #2292's prepared sender mechanism. Normal publication still follows room connection and capture readiness. PR #1224's acknowledgement/order fix is separate and is not included in this comparison.

With a controlled 1 s capture delay and 350 ms credential delay, the measured median first decoded audio improves **1,457 → 1,081 ms without preconnect buffering** and **1,458 → 1,078 ms with buffering** (376–380 ms). With buffering, room connection improves **1,385 → 379 ms** because it no longer waits for capture. With immediate capture, first audio is effectively unchanged (444 → 444 ms without buffering, 453 → 453 ms with it).

The expected saving for microphone readiness/first audio is approximately the overlap: `capture + credentials/connection` becomes `max(capture, credentials/connection)`, followed by ordinary publication. It is bounded by the shorter branch, not generally the full permission duration. When credentials are cached and connection is nearby, that saving can be much smaller. With buffering enabled the old flow waited for capture before JOIN, so room membership can improve by the full capture delay even while first audio saves less. These timings do not promise a two-RTT gain.

[Results and exploratory bootstrap intervals](results.md), [all 80 measured samples](samples.json), [run metadata](metadata.json).

## Method

- macOS arm64, local LiveKit 1.13.10, single PC, no injected network delay. No staging or production-network claim. The credential source waits 350 ms in both arms. Capture adds either zero or 1,000 ms before starting the track; zero added delay does not eliminate SDK/audio-device work.
- The candidate uses actual `Session.start()`. The baseline replays the previous Session ordering from the recorded base revision, on the same current SDK build and identical capture dependencies: with buffering, capture/record then fetch/connect (Room publishes the recording track); without buffering, fetch/connect then capture/publish. This is a sequencing A/B, not separately compiled old/new SDK binaries or a physical permission-dialog benchmark.
- A warm manual audio engine supplies PCM through the real WebRTC audio pipeline, avoiding microphone/speaker permission and hardware dependencies. A peer already in the room receives the published audio through the real SFU. A renderer records the first decoded PCM buffer; physical speaker latency and audibility are not measured. This is outgoing user audio at a peer, not an agent greeting or LLM/TTS response.
- Times start immediately before Session startup / the baseline sequence. Connected is the room's connected-state callback. Published/start-returned is immediately after the sequence completes. First decoded audio is the remote renderer callback. No extra public timing API is introduced, and UI rendering/login/download are not measured.
- One excluded warmup pair per condition, ten measured runs per arm, alternating order: 88 total starts, 80 committed samples, no failed samples or sample reruns. Native SDK transport retries remain enabled. All rooms disconnect and captured tracks stop after each run; the manual PCM producer is cancelled and joined.
- Bootstrap intervals use 20,000 independent within-arm resamples, seed 1227, conventional medians and percentile 95% intervals. Ten observations per arm are exploratory; intervals are unadjusted for multiple comparisons and do not estimate production p95.

## Reproduce

Start a local server with loopback RTC candidates enabled (dev keys only), then run from the SDK root:

```sh
LIVEKIT_TESTING_URL=ws://127.0.0.1:18880 \
LIVEKIT_SESSION_BENCHMARK=1 \
LIVEKIT_SESSION_OUTPUT=/tmp/swift-session-samples.json \
xcrun swift test -j 4 --filter SessionStartupLatencyTests
```

Use the normal `LIVEKIT_TESTING_API_KEY` / `LIVEKIT_TESTING_API_SECRET` variables for another server. The benchmark is opt-in and skipped in ordinary test runs. `LIVEKIT_SESSION_REPETITIONS` changes the run count; the committed summary expects ten measured runs per arm.

Source: `Tests/LiveKitCoreTests/Agent/SessionStartupLatencyTests.swift`; PCM fixture: `SessionTestAudioSource.swift`. Regenerate the committed summary without rerunning connections:

```sh
python3 Benchmarks/SessionStartup/analyze.py > /tmp/swift-session-results.md
```

## Behavioral scope

Session startup is atomic: capture/publication failure disconnects the room, stops Session-owned capture and completes teardown before retry. This includes publication failure after a successful connection; earlier Session behavior could leave that room connected.

Preconnect recording starts as soon as capture becomes available, independently of connection. It may therefore start after JOIN. Neither old nor new code can buffer microphone samples before permission/device capture exists; the change removes the guarantee that recording precedes JOIN, not permission-time audio that the old implementation could capture. Agent buffering state reports actual recording. The standalone `Room.withPreConnectAudio` API retains its ordering.
