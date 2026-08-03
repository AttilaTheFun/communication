@preconcurrency internal import WebRTC

/// The ICE connectivity state for a peer connection.
public enum CommunicationICEConnectionState: String, Sendable, CaseIterable {
    /// ICE has not started checking candidates.
    case fresh

    /// ICE is checking candidate pairs.
    case checking

    /// ICE found a usable connection.
    case connected

    /// ICE completed candidate checks.
    case completed

    /// ICE failed to find a usable connection.
    case failed

    /// ICE connectivity was interrupted but may recover.
    case disconnected

    /// ICE was closed.
    case closed

    /// WebRTC reported a state unknown to this wrapper.
    case unknown
}

/// Conversion from raw WebRTC ICE connection states.
extension CommunicationICEConnectionState {
    /// Creates a Swift state wrapper from a WebRTC ICE connection state.
    init(_ state: RTCIceConnectionState) {
        switch state {
        case .new:
            self = .fresh
        case .checking:
            self = .checking
        case .connected:
            self = .connected
        case .completed:
            self = .completed
        case .failed:
            self = .failed
        case .disconnected:
            self = .disconnected
        case .closed:
            self = .closed
        case .count:
            self = .unknown
        @unknown default:
            self = .unknown
        }
    }
}
