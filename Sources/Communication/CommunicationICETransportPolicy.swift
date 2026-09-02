/// The ICE transport policy used by a peer connection.
public enum CommunicationICETransportPolicy: String, Sendable, Codable, CaseIterable {
    /// Allow all candidate types.
    case all

    /// Allow only relay candidates.
    case relay

    /// Exclude host candidates.
    case noHost
}
