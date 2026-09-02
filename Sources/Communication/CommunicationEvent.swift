/// Events emitted by a `CommunicationPeerConnection`.
public enum CommunicationEvent: Sendable, Equatable {
    /// The WebRTC signalling state changed.
    case signalingStateChanged(CommunicationSignalingState)

    /// The ICE connection state changed.
    case iceConnectionStateChanged(CommunicationICEConnectionState)

    /// The overall peer connection state changed.
    case connectionStateChanged(CommunicationConnectionState)

    /// The ICE gathering state changed.
    case iceGatheringStateChanged(CommunicationICEGatheringState)

    /// WebRTC discovered a local ICE candidate that should be sent to the remote peer.
    case localCandidateDiscovered(CommunicationICECandidate)

    /// WebRTC removed local ICE candidates that may need to be removed remotely.
    case localCandidatesRemoved([CommunicationICECandidate])

    /// WebRTC requested a new offer/answer negotiation.
    case negotiationNeeded

    /// A data channel opened.
    case dataChannelOpened(label: String)

    /// A message arrived on a data channel.
    case dataChannelMessage(label: String, message: CommunicationDataChannelMessage)

    /// A data channel changed state.
    case dataChannelStateChanged(label: String, state: CommunicationDataChannelState)

    /// Remote media became available.
    case remoteMediaAdded

    /// Remote media was removed.
    case remoteMediaRemoved
}

extension CommunicationEvent: CustomStringConvertible {
    /// A concise diagnostic description for logs.
    public var description: String {
        switch self {
        case let .signalingStateChanged(state):
            "Signaling: \(state.rawValue)"
        case let .iceConnectionStateChanged(state):
            "ICE: \(state.rawValue)"
        case let .connectionStateChanged(state):
            "Connection: \(state.rawValue)"
        case let .iceGatheringStateChanged(state):
            "ICE gathering: \(state.rawValue)"
        case let .localCandidateDiscovered(candidate):
            "Local ICE candidate: \(candidate.sdpMid ?? "unknown")"
        case let .localCandidatesRemoved(candidates):
            "Removed \(candidates.count) ICE candidates"
        case .negotiationNeeded:
            "Negotiation needed"
        case let .dataChannelMessage(label, message):
            switch message {
            case let .text(text):
                "Data channel \(label) message: \(text.count) chars"
            case let .binary(data):
                "Data channel \(label) message: \(data.count) bytes"
            }
        case let .dataChannelStateChanged(label, state):
            "Data channel \(label) state: \(state.rawValue)"
        case let .dataChannelOpened(label):
            "Data channel opened: \(label)"
        case .remoteMediaAdded:
            "Remote media added"
        case .remoteMediaRemoved:
            "Remote media removed"
        }
    }
}
