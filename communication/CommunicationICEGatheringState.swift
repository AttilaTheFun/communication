@preconcurrency internal import WebRTC

/// The ICE candidate gathering state for a peer connection.
public enum CommunicationICEGatheringState: String, Sendable, CaseIterable {
    /// ICE gathering has not started.
    case fresh

    /// ICE gathering is in progress.
    case gathering

    /// ICE gathering completed.
    case complete

    /// WebRTC reported a state unknown to this wrapper.
    case unknown
}

/// Conversion from raw WebRTC ICE gathering states.
extension CommunicationICEGatheringState {
    /// Creates a Swift state wrapper from a WebRTC ICE gathering state.
    init(_ state: RTCIceGatheringState) {
        switch state {
        case .new:
            self = .fresh
        case .gathering:
            self = .gathering
        case .complete:
            self = .complete
        @unknown default:
            self = .unknown
        }
    }
}
