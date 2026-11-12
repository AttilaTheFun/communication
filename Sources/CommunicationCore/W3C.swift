import Communication
import Foundation

/// The W3C WebRTC dictionaries and states a `WebRTCHost` speaks, and their
/// mapping to and from the API's types: done once, here, for every
/// platform.
enum W3C {
    struct Configuration: Codable, Equatable {
        struct ICEServer: Codable, Equatable {
            var urls: [String]
            var username: String?
            var credential: String?
        }

        /// libwebrtc's own options, which browsers don't have.
        struct Native: Codable, Equatable {
            /// "all" or "lowCost".
            var candidateNetworkPolicy: String
            var gathersIceContinually: Bool
            var allowsIPv6OnWiFi: Bool
        }

        var iceServers: [ICEServer]
        /// "all" or "relay" (W3C); libwebrtc also takes "noHost".
        var iceTransportPolicy: String
        var native: Native
    }

    struct SessionDescription: Codable, Equatable {
        /// "offer", "pranswer", "answer" or "rollback".
        var type: String
        var sdp: String
    }

    struct ICECandidate: Codable, Equatable {
        var candidate: String
        var sdpMid: String?
        var sdpMLineIndex: Int32?
        /// The STUN or TURN server it came from (libwebrtc only).
        var url: String?
    }

    struct OfferOptions: Codable, Equatable {
        var iceRestart: Bool
        var offerToReceiveAudio: Bool
        var offerToReceiveVideo: Bool
        var voiceActivityDetection: Bool
    }

    struct DataChannelInit: Codable, Equatable {
        var ordered: Bool
        var maxPacketLifeTime: Int?
        var maxRetransmits: Int?
        /// With `negotiated`, both sides open it themselves under this id.
        var id: Int32?
        var negotiated: Bool
    }

    // MARK: Encoding

    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "{}"
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        } catch {
            throw CommunicationError(code: .webRTCOperationFailed, message: "The host sent unreadable \(type): \(json)")
        }
    }

    static func configuration(_ configuration: CommunicationConfiguration) -> Configuration {
        Configuration(
            iceServers: configuration.iceServers.map {
                .init(urls: $0.urls, username: $0.username, credential: $0.credential)
            },
            iceTransportPolicy: configuration.iceTransportPolicy.rawValue,
            native: .init(
                candidateNetworkPolicy: configuration.candidateNetworkPolicy.rawValue,
                gathersIceContinually: configuration.gathersIceContinually,
                allowsIPv6OnWiFi: configuration.allowsIPv6OnWiFi
            )
        )
    }

    static func sessionDescription(_ description: CommunicationSessionDescription) -> SessionDescription {
        let type = switch description.kind {
        case .offer: "offer"
        case .provisionalAnswer: "pranswer"
        case .answer: "answer"
        case .rollback: "rollback"
        }
        return SessionDescription(type: type, sdp: description.sdp)
    }

    static func sessionDescription(_ description: SessionDescription) throws -> CommunicationSessionDescription {
        let kind: CommunicationSessionDescription.Kind = switch description.type {
        case "offer": .offer
        case "pranswer": .provisionalAnswer
        case "answer": .answer
        case "rollback": .rollback
        default:
            throw CommunicationError(code: .webRTCOperationFailed, message: "Unknown session description type \(description.type)")
        }
        return CommunicationSessionDescription(kind: kind, sdp: description.sdp)
    }

    static func candidate(_ candidate: CommunicationICECandidate) -> ICECandidate {
        ICECandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex, url: candidate.serverURL)
    }

    static func candidate(_ candidate: ICECandidate) -> CommunicationICECandidate {
        CommunicationICECandidate(sdp: candidate.candidate, sdpMLineIndex: candidate.sdpMLineIndex ?? 0, sdpMid: candidate.sdpMid, serverURL: candidate.url)
    }

    static func offerOptions(_ options: CommunicationOfferOptions) -> OfferOptions {
        OfferOptions(
            iceRestart: options.restartsICE,
            offerToReceiveAudio: options.receivesAudio,
            offerToReceiveVideo: options.receivesVideo,
            voiceActivityDetection: options.usesVoiceActivityDetection
        )
    }

    static func dataChannelInit(_ configuration: CommunicationDataChannelConfiguration) -> DataChannelInit {
        DataChannelInit(
            ordered: configuration.ordered,
            maxPacketLifeTime: configuration.maxRetransmitTimeMilliseconds,
            maxRetransmits: configuration.maxRetransmits,
            id: configuration.channelID,
            negotiated: configuration.channelID != nil
        )
    }

    // MARK: States

    static func signalingState(_ state: String) -> CommunicationSignalingState {
        switch state {
        case "stable": .stable
        case "have-local-offer": .localOffer
        case "have-local-pranswer": .localProvisionalAnswer
        case "have-remote-offer": .remoteOffer
        case "have-remote-pranswer": .remoteProvisionalAnswer
        case "closed": .closed
        default: .unknown
        }
    }

    static func iceConnectionState(_ state: String) -> CommunicationICEConnectionState {
        switch state {
        case "new": .fresh
        case "checking": .checking
        case "connected": .connected
        case "completed": .completed
        case "failed": .failed
        case "disconnected": .disconnected
        case "closed": .closed
        default: .unknown
        }
    }

    static func connectionState(_ state: String) -> CommunicationConnectionState {
        switch state {
        case "new": .fresh
        case "connecting": .connecting
        case "connected": .connected
        case "disconnected": .disconnected
        case "failed": .failed
        case "closed": .closed
        default: .unknown
        }
    }

    static func iceGatheringState(_ state: String) -> CommunicationICEGatheringState {
        switch state {
        case "new": .fresh
        case "gathering": .gathering
        case "complete": .complete
        default: .unknown
        }
    }

    static func dataChannelState(_ state: String) -> CommunicationDataChannelState {
        switch state {
        case "connecting": .connecting
        case "open": .open
        case "closing": .closing
        default: .closed
        }
    }
}
