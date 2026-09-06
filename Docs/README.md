# Communication docs

- The API surface is the `CommunicationPeerConnection` protocol
  (`Sources/Communication/CommunicationPeerConnection.swift`): data channels,
  offer/answer, ICE, events. `CommunicationConnector` makes connections.
- `CommunicationWebRTC` is the Apple backend on stasel/WebRTC.
- Media (microphone, camera, video views) is not in this package. The
  backend exposes `WebRTCPeerConnection.withUnderlying` and
  `setRemoteTrackHandler` as an escape hatch; the separate
  `CommunicationCalling` package builds calls on it.
