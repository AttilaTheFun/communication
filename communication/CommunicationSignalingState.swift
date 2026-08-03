@preconcurrency internal import WebRTC

/// The SDP signalling state for a peer connection.
public enum CommunicationSignalingState: String, Sendable, CaseIterable {
    /// The connection has no outstanding local or remote offer.
    case stable

    /// A local offer has been set.
    case localOffer

    /// A local provisional answer has been set.
    case localProvisionalAnswer

    /// A remote offer has been set.
    case remoteOffer

    /// A remote provisional answer has been set.
    case remoteProvisionalAnswer

    /// The signalling state is closed.
    case closed

    /// WebRTC reported a state unknown to this wrapper.
    case unknown
}

/// Conversion from raw WebRTC signalling states.
extension CommunicationSignalingState {
    /// Creates a Swift state wrapper from a WebRTC signalling state.
    init(_ state: RTCSignalingState) {
        switch state {
        case .stable:
            self = .stable
        case .haveLocalOffer:
            self = .localOffer
        case .haveLocalPrAnswer:
            self = .localProvisionalAnswer
        case .haveRemoteOffer:
            self = .remoteOffer
        case .haveRemotePrAnswer:
            self = .remoteProvisionalAnswer
        case .closed:
            self = .closed
        @unknown default:
            self = .unknown
        }
    }
}
