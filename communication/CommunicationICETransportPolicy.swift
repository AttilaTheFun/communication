@preconcurrency internal import WebRTC

/// The ICE transport policy used by a peer connection.
public enum CommunicationICETransportPolicy: String, Sendable, Codable, CaseIterable {
    /// Allow all candidate types.
    case all

    /// Allow only relay candidates.
    case relay

    /// Exclude host candidates.
    case noHost
}

/// Conversion from Swift ICE transport policy to WebRTC policy.
extension CommunicationICETransportPolicy {
    /// The raw WebRTC ICE transport policy.
    var rtcIceTransportPolicy: RTCIceTransportPolicy {
        switch self {
        case .all:
            .all
        case .relay:
            .relay
        case .noHost:
            .noHost
        }
    }
}
