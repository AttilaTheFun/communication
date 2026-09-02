/// The network-cost policy used while gathering ICE candidates.
public enum CommunicationCandidateNetworkPolicy: String, Sendable, Codable, CaseIterable {
    /// Allow candidates on all available networks.
    case all

    /// Prefer lower-cost networks when gathering candidates.
    case lowCost
}
