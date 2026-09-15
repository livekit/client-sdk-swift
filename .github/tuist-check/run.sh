#!/bin/sh
# Builds an app that consumes the committed tree through Tuist, with LiveKit as
# a per-target dynamic framework: an import that Package.swift does not declare
# as a dependency fails to link here but not under `swift build` (#1126).
set -eu
cd "$(dirname "$0")"
serve=$(mktemp -d)
git clone --quiet --bare ../.. "$serve/client-sdk-swift.git"
git -C "$serve/client-sdk-swift.git" branch ci-check
git daemon --base-path="$serve" --export-all --detach --pid-file="$serve/daemon.pid"
trap 'kill "$(cat "$serve/daemon.pid")"' EXIT
tuist install
tuist generate --no-open
xcodebuild build -quiet -workspace TuistCheck.xcworkspace -scheme TuistCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
