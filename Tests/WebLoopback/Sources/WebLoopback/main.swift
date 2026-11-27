import Communication
import CommunicationCore
import CommunicationWeb
import Foundation
import JavaScriptEventLoop
import JavaScriptKit

// Swift's concurrency on the browser's event loop: the results and events
// the JavaScript sends resume tasks there.
JavaScriptEventLoop.installGlobalExecutor()

/// Reports to the page (Page/run.mjs waits for `webLoopback`).
@MainActor func report(_ outcome: String) {
    print("web loopback: \(outcome)")
    JSObject.global.webLoopback = .string(outcome)
}

/// Two connections in one page over the browser's WebRTC: negotiated with
/// complete descriptions, a channel opened, text and bytes both ways; labels
/// in use (a second local "chat" refused, and a "dup" from the caller
/// arriving while the callee has its own, negotiated, turned away: the
/// caller's closes and the callee's stays open) with "chat" still carrying
/// text after; and close.
@MainActor func loopback() async throws {
    let connector = HostConnector(host: WebWebRTCHost())
    let config = CommunicationConfiguration(iceServers: [])
    let caller = try connector.makePeerConnection(configuration: config)
    let callee = try connector.makePeerConnection(configuration: config)
    let callerEvents = Events(caller.events)
    let calleeEvents = Events(callee.events)

    try await caller.openDataChannel(label: "chat")
    try await caller.setLocalDescription(try await caller.offer())
    try await gathered(caller)
    guard let offer = await caller.localDescription else { throw Failure("no offer") }
    try await callee.setRemoteDescription(offer)
    try await callee.setLocalDescription(try await callee.answer())
    try await gathered(callee)
    guard let answer = await callee.localDescription else { throw Failure("no answer") }
    try await caller.setRemoteDescription(answer)

    try await expect(callerEvents, "the caller's channel opens") { $0 == .dataChannelOpened(label: "chat") }
    try await expect(calleeEvents, "the callee sees it open") { $0 == .dataChannelOpened(label: "chat") }

    try await caller.send(text: "hello")
    try await expect(calleeEvents, "text crosses") { $0 == .dataChannelMessage(label: "chat", message: .text("hello")) }
    try await callee.send(data: Data([1, 2, 3]), on: "chat")
    try await expect(callerEvents, "bytes cross") {
        $0 == .dataChannelMessage(label: "chat", message: .binary(Data([1, 2, 3])))
    }

    // A second "chat" of the callee's own: refused, its label in use.
    if (try? await callee.openDataChannel(label: "chat")) != nil { throw Failure("a second chat was opened") }
    print("web loopback: a second chat is refused")
    // The callee's own "dup", negotiated (stream 10), so the caller never
    // hears of it; then the caller's, which arrives while it's open.
    try await callee.openDataChannel(label: "dup", configuration: CommunicationDataChannelConfiguration(channelID: 10))
    try await expect(calleeEvents, "the callee's dup opens") { $0 == .dataChannelOpened(label: "dup") }
    try await caller.openDataChannel(label: "dup")
    try await expect(callerEvents, "the caller's dup is turned away") {
        $0 == .dataChannelStateChanged(label: "dup", state: .closed)
    }
    try await Task.sleep(nanoseconds: 1_000_000_000)
    if await calleeEvents.saw({ $0 == .dataChannelStateChanged(label: "dup", state: .closed) }) {
        throw Failure("the callee's own dup was closed")
    }
    print("web loopback: the callee's dup stays open")
    try await caller.send(text: "after dup")
    try await expect(calleeEvents, "chat carries text after dup") {
        $0 == .dataChannelMessage(label: "chat", message: .text("after dup"))
    }

    await caller.close()
    await callee.close()
    guard await callerEvents.waitForEnd() else { throw Failure("closing didn't end the events") }
}

func gathered(_ peer: any CommunicationPeerConnection) async throws {
    for _ in 0..<200 {
        if await peer.iceGatheringState == .complete { return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw Failure("ICE gathering didn't complete in 10 s")
}

func expect(_ events: Events, _ what: String, _ predicate: @escaping @Sendable (CommunicationEvent) -> Bool) async throws {
    guard await events.wait(predicate) else { throw Failure(what) }
    print("web loopback: \(what)")
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = "failed: \(description)" }
}

/// A connection's events as they come.
actor Events {
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
        for _ in 0..<400 {
            if seen.contains(where: predicate) { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return false
    }

    func saw(_ predicate: @Sendable (CommunicationEvent) -> Bool) -> Bool {
        seen.contains(where: predicate)
    }

    func waitForEnd() async -> Bool {
        for _ in 0..<400 {
            if ended { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return false
    }
}

Task { @MainActor in
    do {
        try await loopback()
        report("ok")
    } catch {
        report("\(error)")
    }
}
