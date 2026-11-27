# Communication on every platform

Goal (Logan, 2026-11-11): Communication is a public, pure Swift package, in
the Swift 6 language mode with strict concurrency and warnings as errors.
It's a thin wrapper over WebRTC with the same API, working out of the box,
on iOS, macOS and visionOS, the web (wasm), Android, Linux and Windows.

No Isomer (Logan, 2026-11-27): Communication doesn't depend on Isomer. That
replaces the 2026-11-11 plan, which injected the web and Android backends
through Isomer's swift_ffi. Apps on Isomer use the package like any other.

## Today

- `Communication`: the API. It's spec-shaped (`CommunicationPeerConnection`,
  data channels, offer/answer, ICE, tracks, senders, receivers,
  transceivers), with no WebRTC import and no dependencies.
- `CommunicationCore`: the implementation, shared Swift over `WebRTCHost`, a
  plain Swift protocol (signaling and data channels so far).
- `CommunicationWebRTC`: the Apple backend, over LiveKit's
  `LiveKitWebRTC.xcframework` (Objective-C, `LK` prefix). It covers iOS,
  macOS and visionOS, through our fork until webrtc-sdk/webrtc#318 ships
  (`README.md`, To do). Its `LiveKitWebRTCHost` runs `CommunicationCore` over
  real WebRTC. `WebRTCConnector` still holds media.
- Elsewhere only `Communication` and `CommunicationCore` build, with no
  backend under them. P2PRC's web and Android clients do WebRTC outside this
  package: JavaScript over the browser's `RTCPeerConnection`, and Kotlin over
  `org.webrtc`.

## The shape: one shared implementation, three backends

```
Communication              the API
CommunicationCore          the implementation, shared Swift, no #if
  └─ WebRTCHost            the primitives it needs, a plain Swift protocol
       ├─ Apple            Swift over LiveKit's xcframework (as today)
       ├─ native           Swift over CWebRTC: Linux, Windows and Android
       └─ web              Swift over wasm imports, with JavaScript the package ships
```

- **`CommunicationCore`** implements `CommunicationPeerConnection` and
  `CommunicationConnector` once: connection and ICE state, the `AsyncStream`
  of events, the data-channel registry, waiting on gathering, ICE restarts,
  and the conversions between API values and the host's plain values. It's
  the same Swift on every platform, with no `#if`.
- **`WebRTCHost`** is the narrow surface underneath, plain values only:
  - create and close a connection;
  - create an offer or answer, and set the local and remote descriptions;
  - add a remote candidate and restart ICE;
  - open a data channel, send text or bytes, and close it;
  - events pulled back (`nextEvent(connection:)`: candidates, state changes,
    a channel opened, a message, a close), keyed by connection and channel id.

  It speaks W3C: JSON dictionaries, W3C state names, `[UInt8]` bytes.

### Native: Linux, Windows and Android over CWebRTC

Android goes native too, the same backend as Linux and Windows, with no Java
in the data path.

- **The library:** LiveKit's prebuilt static libwebrtc (livekit/rust-sdks
  `webrtc-<commit>` releases), from the same webrtc-sdk tree as the Apple
  xcframework. Each release has `linux-{x64,arm64}`, `win-{x64,arm64}` and
  `android-{arm,arm64,x64}`. It's built with Chromium's own libc++
  (`use_custom_libcxx`, namespace `std::__Cr`) and carries it, so it needs
  no system C++ library.
- **CWebRTC:** a small C++ shim over libwebrtc's C++ API, with a C API
  (`cwebrtc.h`). We compile it against the release's headers with its
  defines and Chromium's libc++, and merge it into the release's
  `libwebrtc.a` as one static library, `libcwebrtc.a`. It also defines weak
  no-op `XOpenDisplay`, `XCloseDisplay` and `XQueryKeymap`, which typing
  detection references: there's no display, so no X11 is needed.
- **Packaging:** the libraries are an SE-0482 artifact bundle
  (`CWebRTC.artifactbundle`, `staticLibrary`, a variant per triple, with the
  header and module map). It's attached to Communication's GitHub releases
  and named by URL and checksum in `Package.swift`
  (`.binaryTarget(url:checksum:)`). The Swift side links `m` through
  `linkerSettings`: no `unsafeFlags`, so the package works as a dependency.
  A CI workflow builds the bundle from a pinned LiveKit release.
- **`CommunicationNative`:** Swift over CWebRTC, conforming to `WebRTCHost`.
  It's the same source on all three platforms.
- **Android's media** needs libwebrtc's JVM and application context for its
  audio device. That's one call an app makes at startup, through the API, not
  a dependency. Data channels don't need it.

**Proved on Linux arm64** (2026-11-27, Swift 6.4.2, LiveKit `webrtc-83af826`):
- the shim compiles with the toolchain's clang 21 against Chromium's libc++
  headers;
- merged into `libwebrtc.a`, a peer-connection factory links and runs from a
  Swift executable built by `swift build`, through an SE-0482 artifact bundle;
- the executable needs only libc, libm and libgcc_s beyond Swift's runtime,
  and Chromium's libc++ sits beside Swift's libstdc++ with no clash.

Windows (a `.lib`, COFF) and Android (through a Swift SDK for Android) are
still to prove the same way.

### Web: wasm imports and the package's JavaScript

- **`CommunicationWeb`:** Swift over a handful of wasm imports in its own
  module (`communication_webrtc`): create, offer and answer, descriptions,
  candidates, channels, send, and a callback export the JavaScript calls with
  each event. Events queue in Swift and are pulled through
  `nextEvent(connection:)`, as everywhere else.
- **`communication_webrtc.js`:** shipped in the package. It implements the
  imports over the browser's `RTCPeerConnection` and `RTCDataChannel`, and
  starts as P2PRC's `index.html` WebRTC code. It's plain ES, with no
  framework.
- **Any loader works:** a page passes the module's imports to whatever
  instantiates the wasm (Isomer's boot, JavaScriptKit's, or a plain
  `WebAssembly.instantiate`). Isomer apps pass them in their own code, so
  Isomer depends on nothing here, and this package depends on nothing there.

### Media

Media (tracks, capture, playback, video views) comes after data channels, on
the same pattern: the core keeps the API's logic, and the host gains track
primitives. Capture and rendering are per platform by nature and live in the
backends. Then `WebRTCConnector` shrinks to `LiveKitWebRTCHost`.

## Settings for every target

- `swift-tools-version: 6.2` or later (SE-0482 needs it).
- The Swift 6 language mode (`swiftLanguageModes: [.v6]`; strict concurrency
  is its default).
- `.treatAllWarnings(as: .error)` (SE-0443; settings, not `unsafeFlags`, so
  dependents can take the package).
- No `nonisolated(unsafe)`. `@unchecked Sendable` only on the small classes
  that guard a native handle with a lock, each with a comment saying why.

## Order

1. Done (2026-11-11): the settings above. The Apple backend is
   compile-gated (`#if canImport(LiveKitWebRTC)`) and LiveKit's binary is
   Apple-only, so the package builds on Linux (a container with
   swift:6.4.2-noble).
2. Done (2026-11-11): `WebRTCHost` and `CommunicationCore` for signaling and
   data channels, with a loopback host in the tests (two peers in one process,
   no WebRTC). Eight tests pass on Linux.
3. Done (2026-11-16): the Apple adapter, `LiveKitWebRTCHost`. The core runs
   over real WebRTC on macOS: two connections negotiate, open a channel,
   carry text and bytes both ways, and close.
4. Done (2026-11-27): the native route proved on Linux arm64 (above).
5. Done (2026-11-27) on Linux arm64: CWebRTC's data-channel API
   (`CWebRTC/`, with a loopback test in C) and `CommunicationNative`
   (`NativeWebRTCHost`). Over a locally built bundle, the core's
   real-WebRTC test passes: two connections negotiate, open a channel,
   carry text and bytes both ways, and close; so do the core's 8 tests.
6. The bundle built in CI for every native triple, released, and named in
   `Package.swift` by URL and checksum. Then Windows, then Android.
7. `CommunicationWeb` and its JavaScript, tested in a headless browser.
8. P2PRC moves onto Communication on the web and Android, and its own WebRTC
   glue goes.
9. Media.

## Open questions

- **Bundle size.** Each native triple's `libcwebrtc.a` is about 65 MB, and
  the zipped bundle of all seven is several hundred MB, which SwiftPM
  downloads once per checksum. Trimming what the shim doesn't use (desktop
  capture, PipeWire, H.265) means building libwebrtc ourselves rather than
  taking LiveKit's release. That's for later, if the size matters.
- **Windows' C runtime.** LiveKit's Windows libraries are built for MSVC's C
  runtime. Swift on Windows uses the same, but the flavour (`/MT` or `/MD`)
  has to match. To check when proving Windows.
- **Wasm inside native hosts.** A wasm build running in a native host's JS
  engine (Isomer 0.52's JavaScriptSandbox on Android) has no
  RTCPeerConnection. An app there uses the native backend instead.
