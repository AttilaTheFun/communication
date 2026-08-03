import Communication
import XCTest

final class CommunicationPeerConnectionValueTests: XCTestCase {
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
        for _ in 0..<3 {
            do {
                let peer = try CommunicationPeerConnection(configuration: CommunicationConfiguration(iceServers: []))
                await peer.close()
            }
        }
    }
}
