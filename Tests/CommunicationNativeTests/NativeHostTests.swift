#if canImport(CWebRTC)
import Communication
import CommunicationCore
import CommunicationNative
import Foundation
import XCTest

/// The shared implementation (`CommunicationCore`) over real WebRTC on
/// Linux, Windows and Android (`NativeWebRTCHost`, over CWebRTC): two
/// connections in one process, negotiated with complete descriptions, as the host contract has it.
final class NativeHostTests: XCTestCase {
    func testTheCoreConnectsAndCarriesTextAndBytesOverCWebRTC() async throws {
        let connector = HostConnector(host: NativeWebRTCHost())
        let config = CommunicationConfiguration(iceServers: [])
        let caller = try connector.makePeerConnection(configuration: config)
        let callee = try connector.makePeerConnection(configuration: config)
        let callerEvents = Events(caller.events)
        let calleeEvents = Events(callee.events)

        try await caller.openDataChannel(label: "chat")
        try await caller.setLocalDescription(try await caller.offer())
        try await Self.gathered(caller)
        let offer = await caller.localDescription
        try await callee.setRemoteDescription(try XCTUnwrap(offer))
        try await callee.setLocalDescription(try await callee.answer())
        try await Self.gathered(callee)
        let answer = await callee.localDescription
        try await caller.setRemoteDescription(try XCTUnwrap(answer))

        let callerOpen = await callerEvents.wait { $0 == .dataChannelOpened(label: "chat") }
        let calleeOpen = await calleeEvents.wait { $0 == .dataChannelOpened(label: "chat") }
        XCTAssertTrue(callerOpen, "the caller's channel opens")
        XCTAssertTrue(calleeOpen, "the callee sees the caller's channel open")

        try await caller.send(text: "hello")
        let heard = await calleeEvents.wait { $0 == .dataChannelMessage(label: "chat", message: .text("hello")) }
        XCTAssertTrue(heard, "text crosses")

        try await callee.send(data: Data([1, 2, 3]), on: "chat")
        let bytes = await callerEvents.wait { $0 == .dataChannelMessage(label: "chat", message: .binary(Data([1, 2, 3]))) }
        XCTAssertTrue(bytes, "bytes cross")

        await caller.close()
        await callee.close()
        let ended = await callerEvents.waitForEnd()
        XCTAssertTrue(ended, "closing ends the events")
    }

    private static func gathered(_ peer: any CommunicationPeerConnection) async throws {
        for _ in 0..<100 {
            if await peer.iceGatheringState == .complete { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

/// A connection's events as they come, for the test to wait on.
private actor Events {
    private var seen: [CommunicationEvent] = []
    private var ended = false

    init(_ stream: AsyncStream<CommunicationEvent>) {
        Task { [weak self] in
            for await event in stream { await self?.append(event) }
            await self?.end()
        }
    }

    private func append(_ event: CommunicationEvent) { seen.append(event) }
    private func end() { ended = true }

    func wait(_ predicate: @Sendable (CommunicationEvent) -> Bool) async -> Bool {
        for _ in 0..<200 {
            if seen.contains(where: predicate) { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return false
    }

    func waitForEnd() async -> Bool {
        for _ in 0..<200 {
            if ended { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return false
    }
}
#endif
