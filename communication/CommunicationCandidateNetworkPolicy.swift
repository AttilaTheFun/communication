@preconcurrency internal import WebRTC

/// The network-cost policy used while gathering ICE candidates.
public enum CommunicationCandidateNetworkPolicy: String, Sendable, Codable, CaseIterable {
    /// Allow candidates on all available networks.
    case all

    /// Prefer lower-cost networks when gathering candidates.
    case lowCost
}

/// Conversion from Swift candidate network policy to WebRTC policy.
extension CommunicationCandidateNetworkPolicy {
    /// The raw WebRTC candidate network policy.
    var rtcCandidateNetworkPolicy: RTCCandidateNetworkPolicy {
        switch self {
        case .all:
            .all
        case .lowCost:
            .lowCost
        }
    }
}
