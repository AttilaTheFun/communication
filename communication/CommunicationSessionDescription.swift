@preconcurrency internal import WebRTC

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

/// Conversion between Swift session descriptions and WebRTC session descriptions.
extension CommunicationSessionDescription {
    /// Creates a Swift session description from a WebRTC session description.
    init(_ description: RTCSessionDescription) {
        self.init(
            kind: Kind(description.type),
            sdp: description.sdp
        )
    }

    /// The raw WebRTC session description represented by this value.
    var rtcSessionDescription: RTCSessionDescription {
        RTCSessionDescription(
            type: kind.rtcSdpType,
            sdp: sdp
        )
    }
}

/// Conversion between Swift SDP description kinds and WebRTC SDP types.
extension CommunicationSessionDescription.Kind {
    /// Creates a Swift description kind from a WebRTC SDP type.
    fileprivate init(_ type: RTCSdpType) {
        switch type {
        case .offer:
            self = .offer
        case .prAnswer:
            self = .provisionalAnswer
        case .answer:
            self = .answer
        case .rollback:
            self = .rollback
        @unknown default:
            self = .offer
        }
    }

    /// The raw WebRTC SDP type represented by this value.
    fileprivate var rtcSdpType: RTCSdpType {
        switch self {
        case .offer:
            .offer
        case .provisionalAnswer:
            .prAnswer
        case .answer:
            .answer
        case .rollback:
            .rollback
        }
    }
}
