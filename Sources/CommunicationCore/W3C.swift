import Communication
import Foundation

/// The W3C WebRTC dictionaries and states a `WebRTCHost` speaks, and their
/// mapping to and from the API's types: done once, here, for every
/// platform.
package enum W3C {
    package struct Configuration: Codable, Equatable {
        package struct ICEServer: Codable, Equatable {
            package var urls: [String]
            package var username: String?
            package var credential: String?
        }

        /// libwebrtc's own options, which browsers don't have.
        package struct Native: Codable, Equatable {
            /// "all" or "lowCost".
            package var candidateNetworkPolicy: String
            package var gathersIceContinually: Bool
            package var allowsIPv6OnWiFi: Bool
        }

        package var iceServers: [ICEServer]
        /// "all" or "relay" (W3C); libwebrtc also takes "noHost".
        package var iceTransportPolicy: String
        package var native: Native
    }

    package struct SessionDescription: Codable, Equatable {
        /// "offer", "pranswer", "answer" or "rollback".
        package var type: String
        package var sdp: String
    }

    package struct ICECandidate: Codable, Equatable {
        package var candidate: String
        package var sdpMid: String?
        package var sdpMLineIndex: Int32?
        /// The STUN or TURN server it came from (libwebrtc only).
        package var url: String?
    }

    package struct OfferOptions: Codable, Equatable {
        package var iceRestart: Bool
        package var offerToReceiveAudio: Bool
        package var offerToReceiveVideo: Bool
        package var voiceActivityDetection: Bool
    }

    package struct DataChannelInit: Codable, Equatable {
        package var ordered: Bool
        package var maxPacketLifeTime: Int?
        package var maxRetransmits: Int?
        /// With `negotiated`, both sides open it themselves under this id.
        package var id: Int32?
        package var negotiated: Bool
    }

    // MARK: Encoding

    package static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "{}"
    }

    package static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        } catch {
            throw CommunicationError(code: .webRTCOperationFailed, message: "The host sent unreadable \(type): \(json)")
        }
    }

    package static func configuration(_ configuration: CommunicationConfiguration) -> Configuration {
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

    package static func sessionDescription(_ description: CommunicationSessionDescription) -> SessionDescription {
        let type = switch description.kind {
        case .offer: "offer"
        case .provisionalAnswer: "pranswer"
        case .answer: "answer"
        case .rollback: "rollback"
        }
        return SessionDescription(type: type, sdp: description.sdp)
    }

    package static func sessionDescription(_ description: SessionDescription) throws -> CommunicationSessionDescription {
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

    package static func candidate(_ candidate: CommunicationICECandidate) -> ICECandidate {
        ICECandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex, url: candidate.serverURL)
    }

    package static func candidate(_ candidate: ICECandidate) -> CommunicationICECandidate {
        CommunicationICECandidate(sdp: candidate.candidate, sdpMLineIndex: candidate.sdpMLineIndex ?? 0, sdpMid: candidate.sdpMid, serverURL: candidate.url)
    }

    package static func offerOptions(_ options: CommunicationOfferOptions) -> OfferOptions {
        OfferOptions(
            iceRestart: options.restartsICE,
            offerToReceiveAudio: options.receivesAudio,
            offerToReceiveVideo: options.receivesVideo,
            voiceActivityDetection: options.usesVoiceActivityDetection
        )
    }

    package static func dataChannelInit(_ configuration: CommunicationDataChannelConfiguration) -> DataChannelInit {
        DataChannelInit(
            ordered: configuration.ordered,
            maxPacketLifeTime: configuration.maxRetransmitTimeMilliseconds,
            maxRetransmits: configuration.maxRetransmits,
            id: configuration.channelID,
            negotiated: configuration.channelID != nil
        )
    }

    // MARK: Back to the API (for adapters over libwebrtc)

    package static func configuration(_ configuration: Configuration) -> CommunicationConfiguration {
        CommunicationConfiguration(
            iceServers: configuration.iceServers.map {
                CommunicationICEServer(urls: $0.urls, username: $0.username, credential: $0.credential)
            },
            iceTransportPolicy: CommunicationICETransportPolicy(rawValue: configuration.iceTransportPolicy) ?? .all,
            candidateNetworkPolicy: CommunicationCandidateNetworkPolicy(rawValue: configuration.native.candidateNetworkPolicy) ?? .all,
            gathersIceContinually: configuration.native.gathersIceContinually,
            allowsIPv6OnWiFi: configuration.native.allowsIPv6OnWiFi
        )
    }

    package static func offerOptions(_ options: OfferOptions) -> CommunicationOfferOptions {
        CommunicationOfferOptions(
            receivesAudio: options.offerToReceiveAudio,
            receivesVideo: options.offerToReceiveVideo,
            restartsICE: options.iceRestart,
            usesVoiceActivityDetection: options.voiceActivityDetection
        )
    }

    package static func dataChannelConfiguration(_ channel: DataChannelInit) -> CommunicationDataChannelConfiguration {
        CommunicationDataChannelConfiguration(
            ordered: channel.ordered,
            maxRetransmitTimeMilliseconds: channel.maxPacketLifeTime,
            maxRetransmits: channel.maxRetransmits,
            channelID: channel.negotiated ? channel.id : nil
        )
    }

    package static func name(_ state: CommunicationSignalingState) -> String {
        switch state {
        case .stable: "stable"
        case .localOffer: "have-local-offer"
        case .localProvisionalAnswer: "have-local-pranswer"
        case .remoteOffer: "have-remote-offer"
        case .remoteProvisionalAnswer: "have-remote-pranswer"
        case .closed: "closed"
        case .unknown: "unknown"
        }
    }

    package static func name(_ state: CommunicationICEConnectionState) -> String {
        state == .fresh ? "new" : state.rawValue
    }

    package static func name(_ state: CommunicationConnectionState) -> String {
        state == .fresh ? "new" : state.rawValue
    }

    package static func name(_ state: CommunicationICEGatheringState) -> String {
        state == .fresh ? "new" : state.rawValue
    }

    // MARK: States

    package static func signalingState(_ state: String) -> CommunicationSignalingState {
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

    package static func iceConnectionState(_ state: String) -> CommunicationICEConnectionState {
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

    package static func connectionState(_ state: String) -> CommunicationConnectionState {
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

    package static func iceGatheringState(_ state: String) -> CommunicationICEGatheringState {
        switch state {
        case "new": .fresh
        case "gathering": .gathering
        case "complete": .complete
        default: .unknown
        }
    }

    package static func dataChannelState(_ state: String) -> CommunicationDataChannelState {
        switch state {
        case "connecting": .connecting
        case "open": .open
        case "closing": .closing
        default: .closed
        }
    }
}
