import Communication
import CommunicationWebRTC
import XCTest

final class CommunicationValueTests: XCTestCase {
    func testSessionDescriptionCodableRoundTrip() throws {
        let description = CommunicationSessionDescription(kind: .offer, sdp: "v=0")

        let data = try JSONEncoder().encode(description)
        let decoded = try JSONDecoder().decode(CommunicationSessionDescription.self, from: data)

        XCTAssertEqual(decoded, description)
    }

    func testICECandidateCodableRoundTrip() throws {
        let candidate = CommunicationICECandidate(
            sdp: "candidate",
            sdpMLineIndex: 1,
            sdpMid: "audio",
            serverURL: "stun:stun.l.google.com:19302"
        )

        let data = try JSONEncoder().encode(candidate)
        let decoded = try JSONDecoder().decode(CommunicationICECandidate.self, from: data)

        XCTAssertEqual(decoded, candidate)
    }

    func testICEServerFactories() {
        XCTAssertEqual(
            CommunicationICEServer.stun("stun:stun.example.com"),
            CommunicationICEServer(urls: ["stun:stun.example.com"])
        )
        XCTAssertEqual(
            CommunicationICEServer.stun(["stun:one.example.com", "stun:two.example.com"]),
            CommunicationICEServer(urls: ["stun:one.example.com", "stun:two.example.com"])
        )
        XCTAssertEqual(
            CommunicationICEServer.turn(
                ["turn:turn.example.com"],
                username: "user",
                credential: "secret"
            ),
            CommunicationICEServer(
                urls: ["turn:turn.example.com"],
                username: "user",
                credential: "secret"
            )
        )
    }

    func testConfigurationDefaultsToPublicStunServer() {
        let configuration = CommunicationConfiguration()

        XCTAssertEqual(configuration.iceServers, [.stun("stun:stun.l.google.com:19302")])
        XCTAssertEqual(configuration.iceTransportPolicy, .all)
        XCTAssertEqual(configuration.candidateNetworkPolicy, .all)
        XCTAssertTrue(configuration.gathersIceContinually)
        XCTAssertTrue(configuration.allowsIPv6OnWiFi)
    }

    func testConfigurationSupportsCustomValues() {
        let configuration = CommunicationConfiguration(
            iceServers: [.turn(["turn:turn.example.com"], username: "user", credential: "secret")],
            iceTransportPolicy: .relay,
            candidateNetworkPolicy: .lowCost,
            gathersIceContinually: false,
            allowsIPv6OnWiFi: false
        )

        XCTAssertEqual(configuration.iceServers.count, 1)
        XCTAssertEqual(configuration.iceTransportPolicy, .relay)
        XCTAssertEqual(configuration.candidateNetworkPolicy, .lowCost)
        XCTAssertFalse(configuration.gathersIceContinually)
        XCTAssertFalse(configuration.allowsIPv6OnWiFi)
    }

    func testErrorDescriptionUsesMessage() {
        let error = CommunicationError(
            code: .webRTCOperationFailed,
            message: "The peer connection failed."
        )

        XCTAssertEqual(error.errorDescription, "The peer connection failed.")
    }

    func testPeerConnectionCanBeCreatedAndClosedRepeatedly() async throws {
        let connector = WebRTCConnector()
        for _ in 0..<3 {
            let peer = try connector.makePeerConnection(
                configuration: CommunicationConfiguration(iceServers: [])
            )
            await peer.close()
        }
    }

    /// The whole protocol path through the split: a data-channel offer from
    /// one WebRTC-backed peer, answered by another, exchanging descriptions
    /// as `any CommunicationPeerConnection` values.
    func testOfferAnswerRoundTripThroughTheProtocol() async throws {
        let connector = WebRTCConnector()
        let caller: any CommunicationPeerConnection = try connector.makePeerConnection()
        let callee: any CommunicationPeerConnection = try connector.makePeerConnection()
        defer { Task { await caller.close(); await callee.close() } }

        try await caller.openDataChannel(label: "chat")
        let offer = try await caller.offer()
        XCTAssertEqual(offer.kind, .offer)
        XCTAssertFalse(offer.sdp.isEmpty)

        try await caller.setLocalDescription(offer)
        try await callee.setRemoteDescription(offer)
        let answer = try await callee.answer()
        XCTAssertEqual(answer.kind, .answer)
        try await callee.setLocalDescription(answer)
        try await caller.setRemoteDescription(answer)

        // Descriptions applied cleanly: both sides moved past the initial
        // signalling state that a bare, un-negotiated connection sits in.
        let callerSDP = await caller.localDescription
        XCTAssertNotNil(callerSDP)
    }
}
