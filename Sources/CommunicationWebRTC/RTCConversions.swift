// Conversions between the Communication API's value types and the raw
// WebRTC types this implementation drives. Gathered in one file so the
// API module stays free of any WebRTC import, and `fileprivate` helpers
// (the SDP kind mapping) stay next to their only users.

import Communication
@preconcurrency internal import WebRTC

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

/// Conversion from Swift ICE server values to WebRTC ICE servers.
extension CommunicationICEServer {
    /// The raw WebRTC ICE server represented by this value.
    var rtcIceServer: RTCIceServer {
        RTCIceServer(
            urlStrings: urls,
            username: username,
            credential: credential
        )
    }
}

/// Conversion between Swift ICE candidates and WebRTC ICE candidates.
extension CommunicationICECandidate {
    /// Creates a Swift candidate from a WebRTC candidate.
    init(_ candidate: RTCIceCandidate) {
        self.init(
            sdp: candidate.sdp,
            sdpMLineIndex: candidate.sdpMLineIndex,
            sdpMid: candidate.sdpMid,
            serverURL: candidate.serverUrl
        )
    }

    /// The raw WebRTC candidate represented by this value.
    var rtcIceCandidate: RTCIceCandidate {
        RTCIceCandidate(
            sdp: sdp,
            sdpMLineIndex: sdpMLineIndex,
            sdpMid: sdpMid
        )
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

/// Conversion from Swift offer/answer options to WebRTC media constraints.
extension CommunicationOfferOptions {
    /// The raw WebRTC media constraints used while creating offers and answers.
    var rtcConstraints: RTCMediaConstraints {
        RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: receivesAudio.rtcConstraintValue,
                kRTCMediaConstraintsOfferToReceiveVideo: receivesVideo.rtcConstraintValue,
                kRTCMediaConstraintsIceRestart: restartsICE.rtcConstraintValue,
                kRTCMediaConstraintsVoiceActivityDetection: usesVoiceActivityDetection.rtcConstraintValue,
            ],
            optionalConstraints: nil
        )
    }
}

/// WebRTC media constraint conversion helpers.
private extension Bool {
    /// The string constant WebRTC expects for boolean media constraints.
    var rtcConstraintValue: String {
        self ? kRTCMediaConstraintsValueTrue : kRTCMediaConstraintsValueFalse
    }
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

/// Conversion from raw WebRTC peer connection states.
extension CommunicationConnectionState {
    /// Creates a Swift state wrapper from a WebRTC peer connection state.
    init(_ state: RTCPeerConnectionState) {
        switch state {
        case .new:
            self = .fresh
        case .connecting:
            self = .connecting
        case .connected:
            self = .connected
        case .disconnected:
            self = .disconnected
        case .failed:
            self = .failed
        case .closed:
            self = .closed
        @unknown default:
            self = .unknown
        }
    }
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

/// Conversion from raw WebRTC ICE gathering states.
extension CommunicationICEGatheringState {
    /// Creates a Swift state wrapper from a WebRTC ICE gathering state.
    init(_ state: RTCIceGatheringState) {
        switch state {
        case .new:
            self = .fresh
        case .gathering:
            self = .gathering
        case .complete:
            self = .complete
        @unknown default:
            self = .unknown
        }
    }
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
