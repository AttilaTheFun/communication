# Communication

A consistent, idiomatic, async, strict-concurrency-compatible Swift API for
WebRTC, meant to work across every platform Swift itself supports.

## Modules

- **`Communication`** — the API. The currency types (configuration, ICE
  servers and candidates, session descriptions, data-channel options, events,
  errors) and the `CommunicationPeerConnection` / `CommunicationConnector`
  protocols. It imports nothing but Foundation, so it compiles anywhere Swift
  does; higher-level code holds `any CommunicationPeerConnection` and stays
  oblivious to the platform underneath.

- **`CommunicationWebRTC`** — the Apple (iOS, macOS) implementation, backed by
  Google's WebRTC through the [stasel/WebRTC][stasel] binary distribution.
  `WebRTCConnector` makes `WebRTCPeerConnection`s.

```swift
import Communication
import CommunicationWebRTC

let connector = WebRTCConnector()
let peer = try connector.makePeerConnection(
    configuration: CommunicationConfiguration(
        iceServers: [.stun("stun:stun.l.google.com:19302")]
    )
)
try await peer.openDataChannel(label: "chat")
let offer = try await peer.offer()
// …carry `offer` to the remote peer over your own signalling transport,
// apply what comes back with `setRemoteDescription`, and read
// `peer.events` for ICE candidates and state.
```

Signalling is deliberately outside the API: you own how offers, answers and
ICE candidates reach the other side.

## Platforms

`Communication` builds everywhere. `CommunicationWebRTC` is Apple-only today;
Android, Linux and Windows implementations of the same API are planned, either
as further targets here or by adapting a platform stack behind the protocol.

[stasel]: https://github.com/stasel/WebRTC

## Media

The media half of the WebRTC API is here too, shaped as the spec shapes it:
`CommunicationMediaStreamTrack`, `CommunicationRtpSender`/`Receiver`/
`Transceiver`, `addTrack`/`removeTrack`/`addTransceiver` on the peer
connection, `trackAdded`/`trackRemoved` events, and `CommunicationMediaDevices`
for `getUserMedia` (microphone, camera). The Apple backend renders video
through `WebRTCVideoView.make()` attached to a `WebRTCMediaTrack`. What a
*call* is (which frames start it, how media is negotiated onto an existing
connection) is not WebRTC's business and lives in the Convo Protocol.

## Layout

`Sources/` (Communication, CommunicationWebRTC), `Tests/`, `Examples/`
(`swift run DataChannelEcho`), `Docs/`, `Tools/`.
