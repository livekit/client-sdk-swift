# Releasing client-sdk-swift

This repository releases with [verwalter][verwalter].
The commands that are the same in every repository are in the
[verwalter cheat sheet][cheat].
This file holds what is specific to this repository.

## Packages

| Package | Tag | Goes to |
|---|---|---|
| `client-sdk-swift` | `<version>`, without a `v` | SwiftPM (the tag). CocoaPods (`livekit/podspecs`). The XCFramework (`livekit/client-sdk-swift-xcframework`). The docs (`/reference/client-sdk-swift/`). |

The version is in `.version`, `LiveKitClient.podspec`,
`Sources/LiveKit/LiveKit.swift` and `README.md`. The release PR moves all four.

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
| `release.yaml` | The release PR merges. | Builds the XCFramework, tags, creates the GitHub release, then calls the three workflows below. |
| `publish-xcframework.yaml` | Called by `release.yaml`, or run by hand. | Builds the XCFramework, opens a draft release and a PR in `livekit/client-sdk-swift-xcframework`. |
| `publish-podspec.yaml` | Called by `release.yaml`, or run by hand. | Opens a PR with the podspec in `livekit/podspecs`. |
| `publish-docs.yaml` | Called by `release.yaml` for a final version, or run by hand. | Uploads the DocC site to S3. |
| `pre-release.yaml` | Run by hand. | Opens an rc PR. |

## Release

1. Merge the release PR.
2. Watch the run of `release.yaml`: `gh run list --workflow release.yaml --limit 1`.
3. Merge the PR in `livekit/podspecs` and the PR in `livekit/client-sdk-swift-xcframework`, and publish the draft release there.

A complete release has these results:

- The tag `<version>` has a public GitHub release.
- `livekit/podspecs` has `LiveKitClient/<version>`.
- `livekit/client-sdk-swift-xcframework` has a public release `<version>` with `LiveKit.xcframework.zip`.
- For a final version, the docs show `<version>`.

## Pre-release

`gh workflow run pre-release.yaml --ref main`. Merging the rc PR tags
`2.20.0-rc.1` and publishes the podspec and the XCFramework. The docs stay on
the last final version.

## A release failed

Find the cause first. The paths by cause are in the
[recovery section][recovery].

| Situation | Command |
|---|---|
| A job failed for a transient reason. | `gh run rerun <run-id> --failed` |
| The workflow file needed a fix, and the fix is on `main`. | `gh workflow run release.yaml -f ref=<tag>` |
| The build failed before the tag, and the fix to `scripts/` is on `main`. | `gh workflow run release.yaml -f ref=<merge commit of the release PR>` |
| Only the XCFramework failed, and the fix is in `scripts/`. | `gh workflow run publish-xcframework.yaml -f version=<tag> -f dry_run=false` |
| Only the podspec failed. | `gh workflow run publish-podspec.yaml -f ref=<tag> -f dry_run=false` |
| Only the docs failed. | `gh workflow run publish-docs.yaml -f ref=<tag> -f dry_run=false` |
| The released commit is wrong. | `verwalter release --abandon <tag>`, then a changeset and the next version. |

`publish-xcframework.yaml` takes `scripts/` from `main`, so a fix to the build
tooling reaches a tag that exists. A fix to the SDK sources needs the next version.

## After a release

Nothing in other repositories updates on its own. The two PRs of step 3 are
the only consumers that this repository writes to.

[verwalter]: https://github.com/livekit/verwalter
[cheat]: https://github.com/livekit/verwalter/blob/main/docs/cheat-sheet.md
[recovery]: https://github.com/livekit/verwalter/blob/main/docs/release-workflows.md#recovery
