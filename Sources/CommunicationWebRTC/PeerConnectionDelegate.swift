#if canImport(LiveKitWebRTC)
import Foundation

import Communication

@preconcurrency internal import LiveKitWebRTC

/// WebRTC delegate adapter that converts callbacks into `CommunicationEvent` values.
final class PeerConnectionDelegate: NSObject, LKRTCPeerConnectionDelegate, @unchecked Sendable {
    /// Callback used to forward translated delegate events to `PeerConnectionCore`.
    private let emit: @Sendable (CommunicationEvent) -> Void

    /// Called when the remote opens a channel, so the registry can own it.
    private let adoptDataChannel: @Sendable (LKRTCDataChannel) -> Void

    /// Creates a delegate adapter.
    init(
        emit: @escaping @Sendable (CommunicationEvent) -> Void,
        adoptDataChannel: @escaping @Sendable (LKRTCDataChannel) -> Void = { _ in }
    ) {
        self.emit = emit
        self.adoptDataChannel = adoptDataChannel
    }

    /// Forwards signalling-state changes.
    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange stateChanged: LKRTCSignalingState
    ) {
        emit(.signalingStateChanged(CommunicationSignalingState(stateChanged)))
    }

    /// Forwards legacy stream-add callbacks as remote media availability.
    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didAdd stream: LKRTCMediaStream
    ) {
        // Unified Plan: the receiver callback below reports the track.
    }

    /// Forwards legacy stream-remove callbacks as remote media removal.
    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didRemove stream: LKRTCMediaStream
    ) {
        // See above.
    }

    /// Forwards WebRTC negotiation-needed callbacks.
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {
        emit(.negotiationNeeded)
    }

    /// Forwards ICE connection-state changes.
    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange newState: LKRTCIceConnectionState
    ) {
        emit(.iceConnectionStateChanged(CommunicationICEConnectionState(newState)))
    }

    /// Forwards ICE gathering-state changes.
    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange newState: LKRTCIceGatheringState
    ) {
        emit(.iceGatheringStateChanged(CommunicationICEGatheringState(newState)))
    }

    /// Forwards newly generated local ICE candidates.
    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didGenerate candidate: LKRTCIceCandidate
    ) {
        emit(.localCandidateDiscovered(CommunicationICECandidate(candidate)))
    }

    /// Forwards local ICE candidate removals.
    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didRemove candidates: [LKRTCIceCandidate]
    ) {
        emit(.localCandidatesRemoved(candidates.map(CommunicationICECandidate.init)))
    }

    /// Adopts a channel the remote opened. The `dataChannelOpened` event is
    /// emitted by the registry once the channel actually reaches `.open`,
    /// rather than here where it may still be connecting.
    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didOpen dataChannel: LKRTCDataChannel
    ) {
        adoptDataChannel(dataChannel)
    }

    /// Forwards overall peer connection-state changes.
    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChange newState: LKRTCPeerConnectionState
    ) {
        emit(.connectionStateChanged(CommunicationConnectionState(newState)))
    }

    /// Forwards Unified Plan receiver additions as remote media availability.
    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didAdd rtpReceiver: LKRTCRtpReceiver,
        streams mediaStreams: [LKRTCMediaStream]
    ) {
        guard let track = rtpReceiver.track else { return }
        emit(.trackAdded(kind: track.kind == kLKRTCMediaStreamTrackKindVideo ? .video : .audio, trackID: track.trackId))
    }

    /// Forwards Unified Plan receiver removals as remote media removal.
    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didRemove rtpReceiver: LKRTCRtpReceiver
    ) {
        if let track = rtpReceiver.track { emit(.trackRemoved(trackID: track.trackId)) }
    }
}
#endif
