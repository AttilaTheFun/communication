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
