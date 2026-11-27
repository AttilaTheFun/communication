# Tools

Tools for this repository's CI; they are not part of the package.

- `cwebrtc_bundle/`: `cwebrtc-bundle`, which builds CWebRTC's SE-0482
  artifact bundle from LiveKit's prebuilt libwebrtc (`Docs/platforms.md`).
  `variant` builds one platform's (LiveKit's `libwebrtc.a` with CWebRTC's
  shim compiled against it and merged in); `assemble` gathers the variants
  into `CWebRTC.artifactbundle`, zips it, and prints the checksum
  `Package.swift` names it by. Run from the repository's root:

  ```sh
  swift run --package-path Tools/cwebrtc_bundle cwebrtc-bundle variant \
      --platform linux-arm64 --livekit webrtc-83af826 --out .build/variants
  swift run --package-path Tools/cwebrtc_bundle cwebrtc-bundle assemble \
      --version 0.1.0 --out .build/CWebRTC.artifactbundle.zip .build/variants
  ```
