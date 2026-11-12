import Communication
import CommunicationCore
import Foundation
import Testing

/// The shared implementation against the loopback host: what every
/// platform's connection does, with no WebRTC underneath.
struct HostPeerConnectionTests {
    /// Two connected peers with a data channel named `chat`, and their logs.
    private func connectedPair() async throws -> (any CommunicationPeerConnection, EventLog, any CommunicationPeerConnection, EventLog) {
        let connector = HostConnector(host: LoopbackHost())
        let a = try connector.makePeerConnection()
        let b = try connector.makePeerConnection()
        let aLog = EventLog(a.events)
        let bLog = EventLog(b.events)
        try await a.openDataChannel(label: "chat")
        let offer = try await a.offer()
        try await a.setLocalDescription(offer)
        try await b.setRemoteDescription(offer)
        let answer = try await b.answer()
        try await b.setLocalDescription(answer)
        try await a.setRemoteDescription(answer)
        #expect(await aLog.wait { $0 == .dataChannelOpened(label: "chat") })
        #expect(await bLog.wait { $0 == .dataChannelOpened(label: "chat") })
        return (a, aLog, b, bLog)
    }

    @Test func connectsAndCarriesTextAndBytes() async throws {
        let (a, aLog, b, bLog) = try await connectedPair()
        #expect(await aLog.wait { $0 == .connectionStateChanged(.connected) })

        try await a.send(text: "hello")
        #expect(await bLog.wait { $0 == .dataChannelMessage(label: "chat", message: .text("hello")) })

        try await b.send(data: Data([1, 2, 3]), on: "chat")
        #expect(await aLog.wait { $0 == .dataChannelMessage(label: "chat", message: .binary(Data([1, 2, 3]))) })
    }

    @Test func reportsSignalingGatheringAndCandidates() async throws {
        let connector = HostConnector(host: LoopbackHost())
        let a = try connector.makePeerConnection()
        let log = EventLog(a.events)
        let offer = try await a.offer()
        try await a.setLocalDescription(offer)

        #expect(await log.wait { $0 == .signalingStateChanged(.localOffer) })
        #expect(await log.wait { $0 == .iceGatheringStateChanged(.complete) })
        #expect(await log.wait {
            if case let .localCandidateDiscovered(candidate) = $0 { candidate.sdpMid == "0" } else { false }
        })
        #expect(await a.iceGatheringState == .complete)
        #expect(await a.localDescription == offer)
    }

    @Test func sendingNeedsAnOpenChannel() async throws {
        let a = try HostConnector(host: LoopbackHost()).makePeerConnection()
        await #expect(throws: CommunicationError.self) { try await a.send(text: "too soon") }
        await #expect(throws: CommunicationError.self) { try await a.send(text: "too soon", on: "chat") }
    }

    @Test func twoOpenChannelsNeedALabel() async throws {
        let (a, _, b, bLog) = try await connectedPair()
        defer { withExtendedLifetime(b) {} }
        try await a.openDataChannel(label: "files")
        #expect(await bLog.wait { $0 == .dataChannelOpened(label: "files") })
        await #expect(throws: CommunicationError.self) { try await a.send(text: "which?") }
        try await a.send(text: "this one", on: "files")
        #expect(await bLog.wait { $0 == .dataChannelMessage(label: "files", message: .text("this one")) })
    }

    @Test func aConnectionLetGoOfDisconnects() async throws {
        let host = LoopbackHost()
        var a: (any CommunicationPeerConnection)? = try HostConnector(host: host).makePeerConnection()
        let log = EventLog(try #require(a).events)
        _ = try await a?.offer()
        a = nil
        #expect(await log.waitForEnd())
    }

    @Test func closeEndsTheEvents() async throws {
        let a = try HostConnector(host: LoopbackHost()).makePeerConnection()
        let log = EventLog(a.events)
        await a.close()
        #expect(await log.waitForEnd())
        #expect(await log.events.contains(.connectionStateChanged(.closed)))
    }

    @Test func mediaIsNotAvailableYet() async throws {
        let connector = HostConnector(host: LoopbackHost())
        let a = try connector.makePeerConnection()
        await #expect(throws: CommunicationError.self) { _ = try await a.addTransceiver(kind: .audio, direction: .sendRecv) }
        #expect(throws: CommunicationError.self) { _ = try connector.makeMediaDevices() }
    }

    @Test func passesTheConfigurationAsW3CJSON() async throws {
        let host = LoopbackHost()
        let a = try HostConnector(host: host).makePeerConnection(
            configuration: CommunicationConfiguration(
                iceServers: [.turn(["turn:example.com"], username: "u", credential: "p")],
                iceTransportPolicy: .relay
            )
        )
        _ = try await a.offer()
        let json = try #require(await host.configurations.first)
        #expect(json.contains(#""iceTransportPolicy":"relay""#))
        #expect(json.contains(#""urls":["turn:example.com"]"#))
        #expect(json.contains(#""username":"u""#))
    }
}

/// Collects a connection's events as they come, for tests to wait on.
actor EventLog {
    private(set) var events: [CommunicationEvent] = []
    private var ended = false

    init(_ stream: AsyncStream<CommunicationEvent>) {
        Task { [weak self] in
            for await event in stream { await self?.append(event) }
            await self?.end()
        }
    }

    private func append(_ event: CommunicationEvent) { events.append(event) }
    private func end() { ended = true }

    /// Whether an event matching `predicate` arrives within two seconds.
    func wait(_ predicate: @Sendable (CommunicationEvent) -> Bool) async -> Bool {
        for _ in 0..<200 {
            if events.contains(where: predicate) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// Whether the stream finishes within two seconds.
    func waitForEnd() async -> Bool {
        for _ in 0..<200 {
            if ended { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
