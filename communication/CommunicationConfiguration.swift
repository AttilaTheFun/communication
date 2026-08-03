@preconcurrency internal import WebRTC

/// WebRTC peer connection configuration expressed without exposing WebRTC types.
public struct CommunicationConfiguration: Sendable, Codable, Equatable {
    /// The STUN or TURN servers used while gathering ICE candidates.
    public var iceServers: [CommunicationICEServer]

    /// The candidate transport policy used by the peer connection.
    public var iceTransportPolicy: CommunicationICETransportPolicy

    /// The network-cost policy used while gathering candidates.
    public var candidateNetworkPolicy: CommunicationCandidateNetworkPolicy

    /// Whether ICE candidate gathering should continue after the initial gathering pass.
    public var gathersIceContinually: Bool

    /// Whether IPv6 is allowed when connected through Wi-Fi.
    public var allowsIPv6OnWiFi: Bool

    /// Creates a WebRTC peer connection configuration.
    ///
    /// - Parameters:
    ///   - iceServers: STUN or TURN servers used for ICE gathering.
    ///   - iceTransportPolicy: The candidate transport policy for the connection.
    ///   - candidateNetworkPolicy: The network-cost policy for candidate gathering.
    ///   - gathersIceContinually: Whether ICE gathering continues after the initial pass.
    ///   - allowsIPv6OnWiFi: Whether IPv6 is allowed on Wi-Fi networks.
    public init(
        iceServers: [CommunicationICEServer] = [.stun("stun:stun.l.google.com:19302")],
        iceTransportPolicy: CommunicationICETransportPolicy = .all,
        candidateNetworkPolicy: CommunicationCandidateNetworkPolicy = .all,
        gathersIceContinually: Bool = true,
        allowsIPv6OnWiFi: Bool = true
    ) {
        self.iceServers = iceServers
        self.iceTransportPolicy = iceTransportPolicy
        self.candidateNetworkPolicy = candidateNetworkPolicy
        self.gathersIceContinually = gathersIceContinually
        self.allowsIPv6OnWiFi = allowsIPv6OnWiFi
    }
}

/// Conversion from public Swift configuration to raw WebRTC configuration.
extension CommunicationConfiguration {
    /// The raw WebRTC configuration consumed by `RTCPeerConnectionFactory`.
    var rtcConfiguration: RTCConfiguration {
        let configuration = RTCConfiguration()
        configuration.iceServers = iceServers.map(\.rtcIceServer)
        configuration.iceTransportPolicy = iceTransportPolicy.rtcIceTransportPolicy
        configuration.candidateNetworkPolicy = candidateNetworkPolicy.rtcCandidateNetworkPolicy
        configuration.continualGatheringPolicy = gathersIceContinually ? .gatherContinually : .gatherOnce
        configuration.disableIPV6OnWiFi = !allowsIPv6OnWiFi
        configuration.sdpSemantics = .unifiedPlan
        return configuration
    }
}
