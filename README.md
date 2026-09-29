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

- **`CommunicationWebRTC`** — the Apple (iOS, macOS, visionOS) implementation,
  backed by Google's WebRTC through LiveKit's binary distribution
  ([livekit/webrtc-xcframework][livekit], classes prefixed `LK`).
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

`Communication` builds everywhere. `CommunicationWebRTC` covers iOS, macOS and
visionOS (device and simulator); there is no Metal video view on visionOS;
Android, Linux and Windows implementations of the same API are planned, either
as further targets here or by adapting a platform stack behind the protocol.

[livekit]: https://github.com/livekit/webrtc-xcframework

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

## Application audio (per-peer playback)

By default the backend plays every connection's received audio, mixed, and
captures the microphone itself. With
`CommunicationConfiguration(audioPlayback: .application)` a connection's
audio is the application's instead: `peer.applicationAudio` pulls that peer's
decoded audio alone (`renderReceived`, mono Float32 at 48 kHz, real-time
safe) and takes microphone audio in (`deliverCaptured`), and
`makeMicrophoneTrack()` makes the local track it feeds. That is what spatial
or per-peer mixing needs. On Apple platforms `WebRTCSpatialAudio` does the
usual thing with it: each peer a positional source in an
`AVAudioEnvironmentNode` (HRTF), the microphone with voice processing feeding
every connection.

```swift
let spatial = WebRTCSpatialAudio()
try await spatial.start(captureMicrophone: false)   // listen only; no permission prompt
// later, on the user's opt-in (asks for permission then):
try await spatial.setMicrophoneEnabled(true)
let peer = try WebRTCConnector().makePeerConnection(
    configuration: CommunicationConfiguration(iceServers: servers, audioPlayback: .application))
let audio = peer.applicationAudio!
_ = try await peer.addTrack(try audio.makeMicrophoneTrack(), streamIDs: ["voice"])
let source = spatial.add(audio)
source.position = AVAudio3DPoint(x: 1, y: 0, z: -2)   // from the peer's pose
```

Each such connection has a WebRTC factory of its own (that is how its playout
is one peer), so keep a room to a mesh of a handful of peers.
