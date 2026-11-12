# Communication on every platform Isomer supports

Goal (Logan, 2026-11-11): Communication is a public, pure Swift package, in
the Swift 6 language mode with strict concurrency and warnings as errors.
It's a thin wrapper over WebRTC with the same API on every platform Isomer
supports: iOS, macOS and visionOS natively, and the web (wasm), Android,
Linux and Windows.

## Today

- `Communication`: the API. It's spec-shaped (`CommunicationPeerConnection`,
  data channels, offer/answer, ICE, tracks, senders, receivers,
  transceivers), with no WebRTC import and no dependencies.
- `CommunicationWebRTC`: the Apple backend, over LiveKit's
  `LiveKitWebRTC.xcframework` (Objective-C, `LK` prefix). It covers iOS,
  macOS and visionOS, through our fork until webrtc-sdk/webrtc#318 ships
  (`README.md`, To do).
- Nothing else. Convo's web and Android clients do WebRTC outside this
  package, through Convo's own coarse host interface (`ConvoHost`:
  `createOffer`, `acceptOffer`, `sendFrame`), which carries data channels
  only. It's implemented in JavaScript over the browser's `RTCPeerConnection`
  and in Kotlin over `stream-webrtc-android` (libwebrtc M125). Those become
  this package's backends, and Convo moves onto the full API.

## Backends

Three implementations of one API. Each is a target the consumer picks per
platform; `CommunicationConnector` hands out peer connections either way.

| Backend | Platforms | WebRTC underneath |
|---|---|---|
| `CommunicationWebRTC` (today's) | iOS, macOS, visionOS | LiveKit's xcframework (Objective-C) |
| `CommunicationNative` (new) | Linux, Windows, Android | libwebrtc's C++ API, prebuilt |
| `CommunicationBrowser` (new) | web (wasm) | the browser's `RTCPeerConnection` |

### Native: libwebrtc in C++, for Linux, Windows and Android

LiveKit publishes prebuilt libwebrtc static libraries with headers for
`linux-{x64,arm64}`, `win-{x64,arm64}` and `android-{arm,arm64,x64}` (also
mac and iOS), as the `webrtc-<commit>` releases of livekit/rust-sdks. They
come from the same webrtc-sdk tree as the Apple xcframework.

- A small C++ target, `CWebRTCShim`, wraps the few classes we use
  (`PeerConnectionFactory`, `PeerConnection`, `DataChannel`, observers) behind
  a C API with plain structs and callbacks. Swift calls the C API; it doesn't
  import libwebrtc's C++ headers. That keeps C++ interop out of the public
  module, and builds one way with SwiftPM and Bazel.
- `CommunicationNative` turns the callbacks into the same `AsyncStream`
  events and async methods as the Apple backend.
- The binary arrives per platform: SwiftPM as an artifact bundle of static
  libraries (SE-0482), Bazel as an `http_archive` per platform.
- Android: Isomer apps run Swift natively on Android, so this one backend
  covers it with no Kotlin. libwebrtc needs the JVM and the app's Context
  once at startup (`webrtc::JVM::Initialize`, the network monitor). The
  shim exports `communication_android_initialize(JavaVM*, jobject context)`.
  Isomer 0.51's `isomer_android_app(native_initializers = [...])` calls it at
  `IsomerRuntime.prepare`; other apps call it themselves.
- Media on these platforms (capture, playback) comes after data channels.
  libwebrtc's audio device module has platform backends; video capture
  needs a per-platform source.

### Browser: RTCPeerConnection, for the web

Wasm can't link libwebrtc; the browser has WebRTC already.

- `CommunicationBrowser` declares wasm imports in a module of its own,
  `communication` (`@_extern(wasm, module: "communication", name: …)`), and
  exports the callbacks the page calls back on. It depends on nothing,
  Isomer included.
- `communication.js`, shipped with the package, implements those imports over
  `RTCPeerConnection` and `RTCDataChannel`. A page adds its imports to the
  wasm instance's import object. Isomer's boot can do that for an Isomer app
  (to settle with Isomer).
- Isomer's alternative is a swift_ffi `@ExportedInterface`, as
  `IsomerNetworkHost` does for URLSession. That ties the package to Isomer,
  so it's not the plan; the open question below says why.

## Settings for every target

- `swift-tools-version: 6.2` or later.
- `.swiftLanguageMode(.v6)` (strict concurrency is the mode's default).
- `.treatAllWarnings(as: .error)` (SE-0443; settings, not `unsafeFlags`, so
  dependents can take the package).
- No `nonisolated(unsafe)`. `@unchecked Sendable` only on the small classes
  that guard C or Objective-C handles with a lock, each with a comment saying
  why.

## Order

1. The package settings above, on today's two targets.
2. `CommunicationNative` with data channels: Linux first, in a Shireworks
   `linux` lease, against LiveKit's prebuilt libwebrtc, with a loopback test
   (two peer connections in one process) as on Apple. Then Windows, then
   Android.
3. `CommunicationBrowser` with data channels, tested in a browser on a
   Shireworks lease, with the same loopback in one page.
4. Convo moves its web and Android clients from `ConvoHost`'s WebRTC calls to
   Communication, as part of its move to Isomer 0.50.
5. Media on the native and browser backends.
6. Public, when Logan says so.

## Open questions

- **Web glue: settled** (with Isomer, 2026-11-11). The package owns it, and
  Isomer 0.51's `imports` hook takes it.
- **Wasm inside native hosts.** From Isomer 0.52, native hosts run wasm builds
  in the platforms' JS engines. WKWebView has RTCPeerConnection, so
  `communication.js` works there as is. Android's JavaScriptSandbox has none,
  so a wasm build there would need the host to bridge to the native backend.
  Natively compiled apps, the usual case, aren't affected.
- **Android: native or Kotlin.** The native backend makes Android the same
  code as Linux and Windows. A Kotlin backend (over `stream-webrtc-android`, as
  Convo has today) would avoid JNI startup. The plan assumes native, falling
  back to Kotlin if libwebrtc's Android startup without its Java layer proves
  brittle.
- **Visibility.** The repository is private today.
