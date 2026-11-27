# Releasing Communication

Logan releases Communication from the Shireworks app, as he does the other
repositories (the `shireworks` topic): CI proposes a draft `vX.Y.N` with its
proof, and he publishes it. Publishing makes the tag. No agent publishes a
draft or makes a tag. Shireworks reads a library's draft by its version
tag, its notes, and its `proof.zip` and `proof-diff.json`. It allows Release
only for a draft of a commit on main whose CI has passed, so a release is
always of main's own commit.

## The version line

`VERSION` holds the committed line, `X.Y.0`. A release is `vX.Y.N`, one past
the highest `vX.Y.*` already released or tagged (the first is `X.Y.1`;
`cwebrtc-bundle next-version`). With a read-only token it can't see drafts,
so the Release run's draft step, which can, refuses a version that exists.
Once a line has a published release, the next proposal needs the line moved
on (`X.(Y+1).0`) in a pull request first, as P2PRC's line rule has it.

## What a release carries

- **CWebRTC.artifactbundle.zip:** CWebRTC's SE-0482 artifact bundle
  (`Docs/platforms.md`), from LiveKit's pinned libwebrtc
  (`Tools/cwebrtc_bundle/Sources/Pins.swift`), one variant per native
  platform, each tested on its own runner.
- **SHA256SUMS:** the bundle's checksum and the proof's.
- **proof.zip and proof-diff.json:** build_tools' `tests-proof` of the
  release's `swift test` runs (Linux over the release's bundle; macOS),
  compared with the release before's (`proof-diff`), as Shireworks Kit's
  releases carry. CWebRTC's C loopback on each variant and the web loopback
  in headless Chromium gate the release too.
- **The notes:** the release's section of CHANGELOG.md, made from the
  `changes/` entries added since the release before.

## Package.swift names its own release's bundle

A tag's `Package.swift` has to name that release's bundle by URL and
checksum, and the tag has to be on a commit of main with CI. So the checksum
reaches main before the release, in a pull request, which works because the
bundle is reproducible. The same pinned libwebrtc, shim and tool give the
same zip byte for byte: the shim is compiled with `-ffile-prefix-map`, and
the zip has fixed times, sorted entries and no extra attributes.

1. **Prepare:** a pull request runs `cwebrtc-bundle prepare` over a
   bundle built from its own commit. It points `Package.swift`'s `CWebRTC`
   at `https://github.com/AttilaTheFun/communication/releases/download/vX.Y.N/CWebRTC.artifactbundle.zip`
   with that bundle's checksum, and adds the release's notes to the top of
   `CHANGELOG.md`.
2. **CI checks it:** on every pull request and push to main, CI rebuilds
   the bundle and fails unless `Package.swift` names it (`cwebrtc-bundle
   verify`). It then tests the package over its own build
   (`cwebrtc-bundle pin --path`), so it never needs the asset, which doesn't
   exist until the release is published.
3. **Release:** the Release workflow, dispatched on main, rebuilds the
   bundle and fails closed unless it's the one `Package.swift` names, at
   the URL of the version it's proposing (`verify --version`). Then it tests,
   proves, and drafts `vX.Y.N` of main's commit with the bundle attached.
4. **Publish:** Logan publishes it in Shireworks. The tag is made on that
   main commit, and the URL its `Package.swift` names now exists.

Between a prepare PR's merge and the release's publication, main names an
asset that doesn't exist yet. Only a package depending on main's branch
itself would notice; one depending on a version never does.

## Doing it

1. `changes/` has an entry for each change since the release before
   (`changes/README.md`).
2. Take the checksum CI's bundle job printed for main's commit (or build
   the bundle: `cwebrtc-bundle variant` for each platform, then
   `assemble --version auto`), run `cwebrtc-bundle prepare --checksum <it>`
   (or `--zip <it>`) `--repository AttilaTheFun/communication`, and open
   the pull request. CI rebuilds the bundle and confirms the checksum.
3. Once it's merged, dispatch the Release workflow on main.
4. Manager checks the draft, then Logan publishes it in Shireworks.
