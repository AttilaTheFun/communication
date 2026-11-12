# Communication on every platform Isomer supports

Goal (Logan, 2026-11-11): Communication is a public, pure Swift package, in
the Swift 6 language mode with strict concurrency and warnings as errors.
It's a thin wrapper over WebRTC with the same API on every platform Isomer
supports: iOS, macOS and visionOS natively, and the web (wasm), Android,
Linux and Windows.

The shape (Logan, 2026-11-11): use Isomer's facilities for injecting native
dependencies on the web and Android, and keep as much of the code as
possible in shared Swift, cross-compiled everywhere, without per-platform
branches.

## Today

- `Communication`: the API. It's spec-shaped (`CommunicationPeerConnection`,
  data channels, offer/answer, ICE, tracks, senders, receivers,
  transceivers), with no WebRTC import and no dependencies.
- `CommunicationWebRTC`: the Apple backend, over LiveKit's
  `LiveKitWebRTC.xcframework` (Objective-C, `LK` prefix). It covers iOS,
  macOS and visionOS, through our fork until webrtc-sdk/webrtc#318 ships
  (`README.md`, To do). It holds the whole implementation (state, events,
  the data-channel registry, conversions), written against Objective-C
  types, so none of it is shared yet.
- Convo's web and Android clients do WebRTC outside this package, through
  Convo's own coarse host interface (`ConvoHost`: `createOffer`,
  `acceptOffer`, `sendFrame`), which carries data channels only. It's
  implemented in JavaScript over the browser's `RTCPeerConnection` and in
  Kotlin over `stream-webrtc-android` (libwebrtc M125).

## The shape: one shared implementation over a small host

```
Communication              the API (as today)
CommunicationCore          the implementation, shared Swift, no #if
  └─ WebRTCHost            the primitives it needs, a protocol
       ├─ Apple adapter    Swift over LiveKit's xcframework
       ├─ web              JavaScript over RTCPeerConnection, injected (swift_ffi)
       ├─ Android          Kotlin over org.webrtc, injected (swift_ffi)
       └─ Linux, Windows   Swift over a C shim over libwebrtc (prebuilt)
```

- **`CommunicationCore`** implements `CommunicationPeerConnection` and
  `CommunicationConnector` once: connection and ICE state, the `AsyncStream`
  of events, the data-channel registry, waiting on gathering, ICE restarts,
  and the conversions between API values and the host's plain values. It's
  the same Swift on every platform, with no `#if`.
- **`WebRTCHost`** is the narrow surface underneath, plain values only (ids,
  strings, bytes, small enums):
  - create and close a connection;
  - create an offer or answer, and set the local and remote descriptions;
  - add a remote candidate and restart ICE;
  - open a data channel, send text or bytes, and close it;
  - events back (candidates, state changes, a data channel opened, a message
    received), keyed by connection and channel id.

  It's an Isomer swift_ffi `@ExportedInterface`, as `IsomerNetworkHost` is
  for URLSession, so the web and Android implement it in their own language
  and Isomer injects it. Native code calls it as an ordinary Swift protocol.
  Settled with Isomer (2026-11-11):
  - **Events are pulled.** `func nextEvent(connection: Int32) async throws ->
    WebRTCEvent` (an `@ExportedEnum` or `@ExportedStruct`: a candidate, a
    state change, a channel opened, a message, a close). The core awaits it in
    a loop, as Isomer's WebSocketHost `next(id:)` works. It's async
    everywhere (a Promise in JS, a suspend fun in Kotlin), keeps one
    interface, and gives backpressure. Swift can't hand the host a closure or
    an interface, so the host doesn't push.
  - **Bytes** are `[UInt8]` (a Uint8Array in JS, a ByteArray in Kotlin), not
    base64.
  - **Installing the host:** an `@ExportedFunction`
    (`installCommunicationHost(_:)`), which Android's Kotlin calls, and so does
    Swift on Apple, Linux and Windows. On wasm, it's a dependency key the core
    looks up, as Isomer's `installInjectedNetworkHosts` reads `isomerHTTP`.
  - **The web glue** is a JS module exporting `webRTCHost(Dependencies)`; a
    page passes it as `boot({ dependencies: { ...webRTCHost(Dependencies) } })`,
    as Isomer's `network.js` does with `browserNetworkHosts`.
  - **The Kotlin** compiles with Isomer's runtime (the generated interface is in
    `dev.isomer.runtime`): `isomer_android_app(services_kt = […],
    services_installer = "CommunicationHost.install()", services_deps =
    [org.webrtc's Maven artifact])`.
  - **Packaging:** Communication is a Bazel module too, published to
    AttilaTheFun/bazel_registry, as Isomer is both a Swift package and a Bazel
    module, so apps reach its JS and Kotlin as labels (filegroups). Through
    rules_swift_package_manager alone, non-Swift files aren't addressable.
- **Adapters** are the only per-platform code, each as thin as it can be:
  - **Web:** JavaScript over `RTCPeerConnection` and `RTCDataChannel`,
    injected as a dependency the way Isomer's network host is. It starts as
    Convo's `index.html` WebRTC code.
  - **Android:** Kotlin over `org.webrtc` (`stream-webrtc-android`), injected
    the same way. It starts as Convo's `AppServices.kt` WebRTC code. The Java
    layer handles libwebrtc's JVM and Context setup itself.
  - **Apple:** Swift over LiveKit's xcframework, conforming to `WebRTCHost`.
    Today's backend shrinks to this, and its logic moves into the core.
  - **Linux and Windows:** Swift over a small C shim (`CWebRTCShim`) over
    libwebrtc's C++ API. It uses LiveKit's prebuilt static libwebrtc
    (livekit/rust-sdks `webrtc-<commit>` releases: `linux-{x64,arm64}`,
    `win-{x64,arm64}`), from the same webrtc-sdk tree as the Apple
    xcframework. Swift sees only the shim's C API, so no C++ interop shows in
    a public module.
- **Media** (tracks, capture, playback, video views) comes after data
  channels, on the same pattern: the core keeps the API's logic, and the host
  gains track primitives. Capture and rendering are inherently per platform
  and live in the adapters.

## Settings for every target

- `swift-tools-version: 6.2` or later.
- The Swift 6 language mode (`swiftLanguageModes: [.v6]`; strict concurrency
  is its default).
- `.treatAllWarnings(as: .error)` (SE-0443; settings, not `unsafeFlags`, so
  dependents can take the package).
- No `nonisolated(unsafe)`. `@unchecked Sendable` only on the small classes
  that guard a native handle with a lock, each with a comment saying why.

## Order

1. Done (2026-11-11): the settings above. The Apple backend is
   compile-gated (`#if canImport(LiveKitWebRTC)`) and LiveKit's binary is
   Apple-only, so the package builds on Linux (a Shireworks container with
   swift:6.4.2-noble).
2. Done (2026-11-11): `WebRTCHost` and `CommunicationCore` for signaling and
   data channels, with a loopback host in the tests (two peers in one process,
   no WebRTC). Eight tests pass on Linux. The host speaks W3C: JSON
   dictionaries, W3C state names, `[UInt8]` bytes, pulled events. A connection
   that's dropped disconnects its host connection.
3. The Apple adapter, with the core in place of today's backend, keeping its
   loopback test green.
4. The web and Android adapters, from Convo's JavaScript and Kotlin, injected
   through Isomer.
5. The Linux and Windows adapter over the C shim.
6. Convo moves onto Communication as part of its move to Isomer 0.50, and
   `ConvoHost` drops its WebRTC calls.
7. Media.
8. Public, when Logan says so.

## Open questions

- **Isomer dependency.** The host is a swift_ffi interface, so the package
  depends on Isomer's Swift package for `IsomerFFI`. Native Apple apps that
  don't use Isomer still build; the macros there produce plain Swift.
- **Wasm inside native hosts.** From Isomer 0.52, native hosts run wasm builds
  in the platforms' JS engines. A wasm build on Android, inside
  JavaScriptSandbox, has no RTCPeerConnection. There the injected host is the
  Kotlin one, which the swift_ffi interface already allows.
- **Visibility.** The repository is private today.
