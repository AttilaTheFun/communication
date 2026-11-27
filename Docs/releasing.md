# Releasing Communication

Logan releases Communication from the Shireworks app, as he does the other
repositories (the `shireworks` topic): CI proposes a draft `vX.Y.N` with its
proof, and he publishes it. Publishing makes the tag. No agent publishes a
draft or makes a tag.

## The version line

`VERSION` holds the committed line, `X.Y.0`. A release is `vX.Y.N`, one past
the highest `vX.Y.*` already released or drafted (the first is `X.Y.1`).
Once a line has a published release, the next proposal needs the line moved
on (`X.(Y+1).0`) in a pull request first, as P2PRC's line rule has it.

## What a release carries

- **CWebRTC.artifactbundle.zip:** CWebRTC's SE-0482 artifact bundle
  (`Docs/platforms.md`), built by the release's own run from LiveKit's
  pinned libwebrtc (`Tools/cwebrtc_bundle/Sources/Pins.swift`), one variant
  per native platform, each tested on its own runner.
- **SHA256SUMS:** the bundle's checksum and the proof's.
- **proof.zip and proof-diff.json:** build_tools' `tests-proof` of the
  release's tests, compared with the release before's (`proof-diff`), as
  Shireworks Kit's releases carry. The tests are:
  - Linux, over the release's own bundle: the core, the native backend's
    real-WebRTC tests, and CWebRTC's C loopback;
  - macOS: the Apple backend's;
  - the web: the web loopback in headless Chromium.
- **The notes:** each `changes/` entry added since the release before.

## Package.swift names its own release's bundle

A tag's `Package.swift` has to name that release's bundle by URL and
checksum, but the checksum only exists once the release's run has built the
bundle. So the release isn't of main's commit itself, but of a commit the
release run makes on top of it, the release commit:

1. The run builds the bundle, tests it, and makes the proof.
2. On a branch `releases/vX.Y.N` from main's commit, it commits:
   - `Package.swift`'s `CWebRTC` binary target pointed at
     `https://github.com/AttilaTheFun/communication/releases/download/vX.Y.N/CWebRTC.artifactbundle.zip`,
     with the checksum it just computed (`cwebrtc-bundle pin`);
   - `CHANGELOG.md` with the release's notes at the top.
3. It drafts `vX.Y.N` with that commit as its target, and the assets above.
4. When Logan publishes it, the tag is made on the release commit, so
   `.package(url: …communication.git, from: "X.Y.N")` resolves to a
   `Package.swift` whose bundle exists and matches.
5. A pull request then brings the release commit back to main, so main names
   the newest published bundle.

Main only ever names a published bundle, so its CI never waits on an asset
that doesn't exist yet. The tests that run before a release use the run's
own bundle, patched in as a path (`cwebrtc-bundle pin --path`), not
main's.

The `cwebrtc-0.1.0` draft from the separate bundle workflow
(`.github/workflows/cwebrtc.yml`) is superseded by this: it isn't published,
and that workflow goes once release.yml is in.

## Doing it

1. `changes/` has an entry for each change since the release before
   (`changes/README.md`).
2. Dispatch the Release workflow on main. It reads the version from
   `VERSION` and the tags.
3. Check the draft (Manager), then Logan publishes it in Shireworks.
4. Merge the release commit's pull request to main.
