# Releasing client-sdk-swift

This repository releases with [verwalter][verwalter].
The commands that are the same in every repository are in the
[verwalter cheat sheet][cheat].
This file holds what is specific to this repository.

## Packages

| Package | Tag | Goes to |
|---|---|---|
| `client-sdk-swift` | `<version>`, without a `v` | SwiftPM (the tag). CocoaPods (two pods in `livekit/podspecs`). The XCFramework (`livekit/client-sdk-swift-xcframework`). The docs (`/reference/client-sdk-swift/`). |

The version is in `.version`, `LiveKitClient.podspec`,
`Sources/LiveKit/LiveKit.swift` and `README.md`. The release PR moves all four.

## Pods and binary dependencies

A release writes two pods to `livekit/podspecs`, the CocoaPods specs repository of LiveKit:

| Pod | Podspec | Source of the pod | Published by |
|---|---|---|---|
| `LiveKitClient` | `LiveKitClient.podspec` | The tag in this repository. | `publish-podspec.yaml` in this repository. |
| `LiveKitClient-XCFramework` | `scripts/xcframework.swift` writes it from `scripts/LiveKitClient-XCFramework.podspec.stencil`. | The asset `LiveKit.xcframework.zip` of the release in `livekit/client-sdk-swift-xcframework`. | `publish-podspec.yaml` in `livekit/client-sdk-swift-xcframework`. |

The SDK has two binary dependencies. Each one is a SwiftPM package and a pod:

| SwiftPM package | Pod in `livekit/podspecs` |
|---|---|
| `livekit/webrtc-xcframework` | `LiveKitWebRTC` |
| `livekit/livekit-ffi-xcframework` | `LiveKitFFI` |

`Package.swift` and `LiveKitClient.podspec` pin the same exact versions. A PR
that moves one pin moves the other. The release PR does not change them.
`scripts/xcframework.swift` reads the pins for the XCFramework podspec from
`Package.swift`.

Both pods must be in `livekit/podspecs` before the release. Their own
repositories publish them. `cocoapods-lint.yaml` resolves them on each PR, so
a pin to a missing pod version fails there.

## Changesets

A PR that changes the SDK adds a file in `.changeset/`:

```bash
verwalter changeset --level patch
```

```markdown
---
"client-sdk-swift": patch
---

Fix local audio not reaching LocalAudioTrack renderers when captured without a connected Room.
```

`patch` for a fix, `minor` for an addition or a behavior change, `major` for a
break. A PR without a user-facing change gets the `internal` label instead.

## Workflows

| File | Trigger | Does |
|---|---|---|
| `changeset-check.yaml` | A PR is opened or updated. | Fails a PR that changes the package without a changeset. |
| `release-pr.yaml` | A push to `main`. | Keeps the release PR `release/main` current. |
| `release.yaml` | The release PR merges. | Tags, creates the GitHub release, then calls the three workflows below. |
| `publish-xcframework.yaml` | Called by `release.yaml`, or run by hand. | Builds the XCFramework, opens a draft release and a PR in `livekit/client-sdk-swift-xcframework`. |
| `publish-podspec.yaml` | Called by `release.yaml`, or run by hand. | Opens a PR with the podspec in `livekit/podspecs`. |
| `publish-docs.yaml` | Called by `release.yaml` when the run released a final version on `main`, or run by hand. | Uploads the DocC site to S3. |

## Release

1. Start a test build of the XCFramework: `gh workflow run publish-xcframework.yaml`.
   It builds the head of `main` and writes nothing.
2. Merge the release PR when that run and the checks of the PR are green.
   `main` requires no check, so GitHub does not block a red PR.
3. Watch the run of `release.yaml`: `gh run list --workflow release.yaml --limit 1`.
4. In `livekit/podspecs`, merge the PR from `publish/LiveKitClient-<version>`.
5. In `livekit/client-sdk-swift-xcframework`, merge the PR from `release/<version>`.
   Then publish the draft release `<version>`, before the PR of a later version merges there.
   Keep this order: GitHub creates the tag of a draft release when the release
   becomes public, on the head of `main`.
6. The public release starts `publish-podspec.yaml` in `livekit/client-sdk-swift-xcframework`.
   That run opens a PR from `publish/LiveKitClient-XCFramework-<version>` in `livekit/podspecs`. Merge it.

A complete release has these results:

- The tag `<version>` has a public GitHub release.
- `livekit/podspecs` has `Specs/LiveKitClient/<version>` and `Specs/LiveKitClient-XCFramework/<version>`.
- `livekit/client-sdk-swift-xcframework` has a public release `<version>` with `LiveKit.xcframework.zip`, and the tag `<version>` holds the `Package.swift` and the podspec of that version.
- For a final version, the docs show `<version>`.

## Pre-release

Not used. If this repository needs an rc, add `pre-release.yaml` from the verwalter examples.

## A release failed

Find the cause first. The paths by cause are in the
[recovery section][recovery].

Only a code owner starts `release.yaml`, or a publish workflow with
`dry_run=false`, by hand. Set `ref` to the release tag or to a commit of
`main`. GitHub does not enforce this: each account with write access can start
such a run. Do not start a publish workflow by hand while the run of
`release.yaml` for that version is active.

| Situation | Command |
|---|---|
| A job failed for a transient reason. | `gh run rerun <run-id> --failed` |
| The workflow file needed a fix, and the fix is on `main`. | `gh workflow run release.yaml -f ref=<tag>`. |
| Only the XCFramework failed, and the fix to `scripts/` is on `main`, with the `internal` label and no changeset. | `gh workflow run publish-xcframework.yaml -f version=<tag> -f dry_run=false` |
| Only the podspec failed. | `gh workflow run publish-podspec.yaml -f ref=<tag> -f dry_run=false` |
| Only the docs failed. | `gh workflow run publish-docs.yaml -f ref=<tag> -f dry_run=false` |
| The PR of step 6 did not open. | `gh workflow run publish-podspec.yaml --repo livekit/client-sdk-swift-xcframework -f ref=<tag> -f dry_run=false` |
| The tag in `livekit/client-sdk-swift-xcframework` holds the `Package.swift` of another version, because step 5 ran in the wrong order. | Merge the PR from `release/<version>` there. Then move the tag to its merge commit at once: `git push --force origin <merge commit>:refs/tags/<version>`. Then run the command of the row above. |
| The released commit is wrong. | `verwalter release --abandon <tag>`, then a changeset and the next version. |

The XCFramework of a release builds one time, after the tag. If that build fails, the
SwiftPM release and the `LiveKitClient` pod are complete, and the XCFramework
and its pod are missing until the build passes.
`publish-xcframework.yaml` takes `scripts/` from `main`, so a fix to the build
tooling reaches a tag that exists. A fix to the SDK sources needs the next version.

## After a release

Nothing in other repositories updates on its own. This repository opens the
PRs of steps 4 and 5. The hosting repository opens the PR of step 6.

[verwalter]: https://github.com/livekit/verwalter
[cheat]: https://github.com/livekit/verwalter/blob/main/docs/cheat-sheet.md
[recovery]: https://github.com/livekit/verwalter/blob/main/docs/release-workflows.md#recovery
