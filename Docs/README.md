# Communication docs

- The API surface is the `CommunicationPeerConnection` protocol
  (`Sources/Communication/CommunicationPeerConnection.swift`): data channels,
  offer/answer, ICE, events. `CommunicationConnector` makes connections.
- `CommunicationWebRTC` is the Apple backend on stasel/WebRTC.
- Media: the WebRTC media API (`CommunicationMedia.swift`) and, in the Apple
  backend, capture through `WebRTCMediaDevices` and Metal video views.