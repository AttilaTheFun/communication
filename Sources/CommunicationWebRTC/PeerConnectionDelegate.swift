import Foundation

import Communication

@preconcurrency internal import WebRTC

/// WebRTC delegate adapter that converts callbacks into `CommunicationEvent` values.
final class PeerConnectionDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    /// Callback used to forward translated delegate events to `PeerConnectionCore`.
    private let emit: @Sendable (CommunicationEvent) -> Void

    /// Called when the remote opens a channel, so the registry can own it.
    private let adoptDataChannel: @Sendable (RTCDataChannel) -> Void

    /// Called when a remote track arrives, so video renderers can attach.
    private let adoptRemoteTrack: @Sendable (RTCMediaStreamTrack) -> Void

    /// Creates a delegate adapter.
    init(
        emit: @escaping @Sendable (CommunicationEvent) -> Void,
        adoptDataChannel: @escaping @Sendable (RTCDataChannel) -> Void = { _ in },
        adoptRemoteTrack: @escaping @Sendable (RTCMediaStreamTrack) -> Void = { _ in }
    ) {
        self.emit = emit
        self.adoptDataChannel = adoptDataChannel
        self.adoptRemoteTrack = adoptRemoteTrack
    }

    /// Forwards signalling-state changes.
    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange stateChanged: RTCSignalingState
    ) {
        emit(.signalingStateChanged(CommunicationSignalingState(stateChanged)))
    }

    /// Forwards legacy stream-add callbacks as remote media availability.
    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd stream: RTCMediaStream
    ) {
        emit(.remoteMediaAdded)
    }

    /// Forwards legacy stream-remove callbacks as remote media removal.
    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove stream: RTCMediaStream
    ) {
        emit(.remoteMediaRemoved)
    }

    /// Forwards WebRTC negotiation-needed callbacks.
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        emit(.negotiationNeeded)
    }

    /// Forwards ICE connection-state changes.
    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceConnectionState
    ) {
        emit(.iceConnectionStateChanged(CommunicationICEConnectionState(newState)))
    }

    /// Forwards ICE gathering-state changes.
    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceGatheringState
    ) {
        emit(.iceGatheringStateChanged(CommunicationICEGatheringState(newState)))
    }

    /// Forwards newly generated local ICE candidates.
    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didGenerate candidate: RTCIceCandidate
    ) {
        emit(.localCandidateDiscovered(CommunicationICECandidate(candidate)))
    }

    /// Forwards local ICE candidate removals.
    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove candidates: [RTCIceCandidate]
    ) {
        emit(.localCandidatesRemoved(candidates.map(CommunicationICECandidate.init)))
    }

    /// Adopts a channel the remote opened. The `dataChannelOpened` event is
    /// emitted by the registry once the channel actually reaches `.open`,
    /// rather than here where it may still be connecting.
    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didOpen dataChannel: RTCDataChannel
    ) {
        adoptDataChannel(dataChannel)
    }

    /// Forwards overall peer connection-state changes.
    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCPeerConnectionState
    ) {
        emit(.connectionStateChanged(CommunicationConnectionState(newState)))
    }

    /// Forwards Unified Plan receiver additions as remote media availability.
    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        if let track = rtpReceiver.track { adoptRemoteTrack(track) }
        emit(.remoteMediaAdded)
    }

    /// Forwards Unified Plan receiver removals as remote media removal.
    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove rtpReceiver: RTCRtpReceiver
    ) {
        emit(.remoteMediaRemoved)
    }
}
