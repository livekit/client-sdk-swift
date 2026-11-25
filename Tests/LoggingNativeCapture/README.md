# Native logging capture fixture

Run `python3 Tests/LoggingNativeCapture/run.py` from the repository root on macOS. Each of nine cases runs in a fresh process because the Rust logger and telemetry opt-out are process-global. The normal `LiveKitLoggingTests` target is included in `LiveKitCI`; this isolated fixture must not be combined with that process. The separate `.github/workflows/logging-native.yaml` job runs this script on the supported macOS/Xcode 26.6 pair. The script uses `/usr/bin/swift` to follow the selected Xcode rather than a user-installed PATH shim.

The released LiveKitFFI 0.15.0 decoder receives an empty data-track packet locally. Its real Rust error must appear exactly once in telemetry with native module/file metadata. An in-memory transport captures exports; no connection, default telemetry destination, physical device, or external grant validation is involved. Synthetic local claims exercise consent policy only.

The cases cover no console, a custom console, disabled console, `ffi: false`, default OSLogger, both bootstrap orders, concurrent bootstrap, and opt-out before install. The no-console case also proves a new native error is produced after opt-out and not exported. Each case checks release of the native manager's delegate. Existing OSLogger receive cancellation behavior is unchanged and is not asserted to be fixed here.
