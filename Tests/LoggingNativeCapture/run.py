#!/usr/bin/env python3
"""Run each process-global native capture case in a fresh macOS process; no network transport."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent
subprocess.run(["/usr/bin/swift", "build", "--build-tests", "--package-path", str(root)], check=True)
for case in ["noConsole", "customConsole", "disabledConsole", "ffiFalse", "defaultConsole",
             "consoleBeforeTelemetry", "telemetryBeforeConsole", "concurrentInitialization", "optOutBeforeInstall"]:
    subprocess.run(["/usr/bin/swift", "test", "--skip-build", "--package-path", str(root),
                    "--filter", "NativeTests." + case], check=True, timeout=30)
