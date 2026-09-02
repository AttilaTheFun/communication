/// A WebRTC session description represented as Swift value data.
public struct CommunicationSessionDescription: Sendable, Codable, Equatable, Hashable {
    /// The kind of SDP session description.
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// An SDP offer.
        case offer

        /// A provisional SDP answer.
        case provisionalAnswer

        /// An SDP answer.
        case answer

        /// An SDP rollback.
        case rollback
    }

    /// The SDP description kind.
    public var kind: Kind

    /// The SDP payload.
    public var sdp: String

    /// Creates a session description.
    ///
    /// - Parameters:
    ///   - kind: The SDP description kind.
    ///   - sdp: The SDP payload.
    public init(kind: Kind, sdp: String) {
        self.kind = kind
        self.sdp = sdp
    }
}
