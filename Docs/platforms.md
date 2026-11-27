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

**Proved on Android arm64** (2026-11-27: swift.org's 6.4.2 Swift SDK for
Android with NDK r27c, LiveKit `webrtc-83af826`'s `android-arm64`, run on
Waydroid, API 33):
- LiveKit's Android libwebrtc is built against the NDK's own libc++
  (`use_custom_libcxx = false`, `std::__ndk1`), the one Swift's Android
  runtime uses too. So the shim is compiled with the NDK's sysroot and
  headers (`--target=aarch64-linux-android28 --sysroot=<ndk>/…/sysroot`),
  and the variant's module map links `log` and `c++_shared`;
- it was built with NDK r30, whose libc++ has `std::__hash_memory`, which
  r27's lacks, so the variant carries `android_stubs.cc`'s weak one; no X11
  stubs;
- the C loopback (every case, label policy included) passes as an Android
  executable;
- `swift build --swift-sdk aarch64-unknown-linux-android28 --build-tests`
  over the variant, then `NativeHostTests` (over real WebRTC) and the core's
  8 tests (`--testing-library swift-testing`) pass on the device, with
  Swift's Android runtime and `libc++_shared.so` beside them.

On an arm64 Linux builder without Rosetta, the SDK's toolset reaches for the
NDK's x86_64 `ld.lld`; a toolset naming the builder's own (`"linker": {
"path": "/usr/bin/ld.lld" }` and `-fuse-ld=/usr/bin/ld.lld`) does instead.
The bundle carries Android's variants (`android-arm64`, `android-x64`,
Swift's triples at API 28) since 0.2.1: `cwebrtc-bundle variant --ndk
<NDK r27c>` compiles the shim against the NDK's sysroot and libc++. CI builds
them and links the C loopback as Android executables; the loopback runs on a
device by hand (2026-11-27: every case passed on Waydroid arm64, API 33, with
`libc++_shared.so` beside it). An app links the variant's `log` and
`c++_shared` and ships `libc++_shared.so`, as Swift's Android runtime already
asks.

Windows doesn't link as Linux and Android do: LiveKit's libwebrtc there is
built with the static C runtime, and Swift's is the dynamic one (Open
questions, below).

### Web: wasm imports and the package's JavaScript

- **`CommunicationWeb`:** Swift over a handful of wasm imports in their own
  module (`communication_webrtc`), declared in a plain C target
  (`CCommunicationWeb`, `import_module`/`import_name` attributes), so no
  Swift experimental feature or flag is needed: create, offer and answer,
  descriptions, candidates, channels, send and close. The C target also
  exports what the JavaScript calls back with (`communication_webrtc_event`,
  `_result`, and `_alloc`/`_free` for what it hands over). Events queue in
  Swift and are pulled through `nextEvent(connection:)`, as everywhere else.
- **The page's executor:** results and events arrive as calls into the
  module's exports, which resume Swift tasks, so the page must run Swift's
  concurrency on the browser's event loop, as Isomer and JavaScriptKit's
  `JavaScriptEventLoop` do.
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
7. Done (2026-11-27): `CommunicationWeb` (`WebWebRTCHost`, over the
   `communication_webrtc` imports declared in `CCommunicationWeb`) and
   `Web/communication_webrtc.js`. Its test (`Tests/WebLoopback`, a package of
   its own over JavaScriptKit) passes in headless Chromium: two connections
   in one page negotiate, open a channel, carry text and bytes both ways,
   and close.
8. P2PRC moves onto Communication on the web and Android, and its own WebRTC
   glue goes.
9. Media.

## Open questions

- **Bundle size.** Each native triple's `libcwebrtc.a` is about 65 MB, and
  the zipped bundle of all seven is several hundred MB, which SwiftPM
  downloads once per checksum. Trimming what the shim doesn't use (desktop
  capture, PipeWire, H.265) means building libwebrtc ourselves rather than
  taking LiveKit's release. That's for later, if the size matters.
- **Windows is parked (Logan, 2026-11-27)** until Nimbus' Studio has room:
  then it builds our own libwebrtc for Windows with `/MD` there, and Windows
  joins the bundle as Linux and Android do. Why:
- **Windows' C runtime (checked 2026-11-27: it doesn't match).** LiveKit's
  Windows libwebrtc (`webrtc-83af826`, win-x64: clang-cl, MSVC's STL,
  `use_custom_libcxx = false`) is built with the static C runtime: its
  objects carry `/DEFAULTLIB:libcmt.lib`, `/DEFAULTLIB:libcpmt.lib` and
  `/FAILIFMISMATCH:"RuntimeLibrary=MT_StaticRelease"`. Swift on Windows is
  built with the dynamic one (`/MD`), so MSVC's linker refuses the two in
  one program (LNK2038). The ways on:
  - **Build libwebrtc for Windows ourselves, with `/MD`** (WebRTC's GN
    builds the static CRT unless told otherwise, so a small patch to its
    `build/config/win` CRT config), from the same tree LiveKit builds, in a
    workflow of our own. It's the one that keeps Windows like Linux: a
    static library in the bundle and nothing else for an app. The cost is
    a WebRTC checkout and build (tens of GB, hours) per libwebrtc release, on
    a runner big enough for it.
  - **Ship CWebRTC as a DLL** (libwebrtc and the shim with their static CRT
    inside it, a C interface out, and nothing of the CRT crossing it). This
    works with LiveKit's library as it is, but SwiftPM can't carry a DLL in
    an artifact bundle yet (SE-0482 is static only), so an app would have to
    put `cwebrtc.dll` beside itself, which isn't out of the box.
  - **A Swift program built with the static CRT** (`-libc MT`) would link,
    but Swift's own runtime on Windows is `/MD`, so that's not something a
    package can ask of its users.
- **Wasm inside native hosts.** A wasm build running in a native host's JS
  engine (Isomer 0.52's JavaScriptSandbox on Android) has no
  RTCPeerConnection. An app there uses the native backend instead.
