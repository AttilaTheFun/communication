import CommunicationCore

/// A `WebRTCHost` with no WebRTC: two connections in one process that pair
/// through the descriptions they exchange, open their data channels once
/// both descriptions are set, and hand each other's messages over. It
/// reports what a real host would, in the same W3C words, so the core's
/// logic is tested on every platform.
actor LoopbackHost: WebRTCHost {
    private struct Connection {
        var peer: Int32?
        var local: String?
        var remote: String?
        var channels: [String] = []
        var connected = false
        var closed = false
        var queue: [WebRTCHostEvent] = []
        var waiting: [CheckedContinuation<WebRTCHostEvent, any Error>] = []
    }

    private var connections: [Int32: Connection] = [:]
    private var nextID: Int32 = 1
    /// The configurations `create` received, as JSON.
    private(set) var configurations: [String] = []

    func create(configuration: String) async throws -> Int32 {
        configurations.append(configuration)
        let id = nextID
        nextID += 1
        connections[id] = Connection()
        return id
    }

    func createOffer(connection: Int32, options: String) async throws -> String {
        #"{"sdp":"loopback \#(connection)","type":"offer"}"#
    }

    func createAnswer(connection: Int32, options: String) async throws -> String {
        #"{"sdp":"loopback \#(connection)","type":"answer"}"#
    }

    func setLocalDescription(connection id: Int32, description: String) async throws {
        connections[id]?.local = description
        let offering = description.contains(#""type":"offer""#)
        post(id, .init(.signalingState, text: offering ? "have-local-offer" : "stable"))
        post(id, .init(.iceGatheringState, text: "gathering"))
        post(id, .init(.candidate, text: #"{"candidate":"candidate:1 1 udp 1 127.0.0.1 9 typ host","sdpMLineIndex":0,"sdpMid":"0"}"#))
        post(id, .init(.iceGatheringState, text: "complete"))
        connectIfReady(id)
    }

    func setRemoteDescription(connection id: Int32, description: String) async throws {
        guard let peer = Self.connectionID(in: description) else {
            throw LoopbackError("not a loopback description: \(description)")
        }
        connections[id]?.remote = description
        connections[id]?.peer = peer
        let offered = description.contains(#""type":"offer""#)
        post(id, .init(.signalingState, text: offered ? "have-remote-offer" : "stable"))
        connectIfReady(id)
    }

    func localDescription(connection: Int32) async -> String {
        connections[connection]?.local ?? ""
    }

    func addCandidate(connection: Int32, candidate: String) async throws {}

    func restartICE(connection: Int32) async {
        post(connection, .init(.negotiationNeeded))
    }

    func openDataChannel(connection id: Int32, label: String, configuration: String) async throws {
        connections[id]?.channels.append(label)
        post(id, .init(.channelState, channel: label, text: "connecting"))
        if connections[id]?.connected == true, let peer = connections[id]?.peer {
            openChannel(label, on: id, and: peer)
        }
    }

    func sendText(connection id: Int32, channel: String, text: String) async throws {
        let peer = try connectedPeer(of: id)
        post(peer, .init(.textMessage, channel: channel, text: text))
    }

    func sendData(connection id: Int32, channel: String, data: [UInt8]) async throws {
        let peer = try connectedPeer(of: id)
        post(peer, .init(.dataMessage, channel: channel, data: data))
    }

    func nextEvent(connection id: Int32) async throws -> WebRTCHostEvent {
        guard var connection = connections[id] else { return .init(.closed) }
        if !connection.queue.isEmpty {
            let event = connection.queue.removeFirst()
            connections[id] = connection
            return event
        }
        if connection.closed { return .init(.closed) }
        return try await withCheckedThrowingContinuation { continuation in
            connections[id]?.waiting.append(continuation)
        }
    }

    func disconnect(connection id: Int32) async {
        guard connections[id]?.closed == false else { return }
        post(id, .init(.connectionState, text: "closed"))
        post(id, .init(.closed))
        connections[id]?.closed = true
    }

    // MARK: Pairing

    private func connectIfReady(_ id: Int32) {
        guard let me = connections[id], me.local != nil, me.remote != nil, !me.connected,
              let peer = me.peer, let other = connections[peer], other.local != nil, other.remote != nil
        else { return }
        for side in [id, peer] {
            connections[side]?.connected = true
            post(side, .init(.connectionState, text: "connecting"))
            post(side, .init(.iceConnectionState, text: "connected"))
            post(side, .init(.connectionState, text: "connected"))
        }
        let labels = me.channels + other.channels.filter { !me.channels.contains($0) }
        for label in labels { openChannel(label, on: id, and: peer) }
    }

    private func openChannel(_ label: String, on first: Int32, and second: Int32) {
        for side in [first, second] {
            if connections[side]?.channels.contains(label) == false {
                connections[side]?.channels.append(label)
            }
            post(side, .init(.channelState, channel: label, text: "open"))
        }
    }

    private func connectedPeer(of id: Int32) throws -> Int32 {
        guard let connection = connections[id], connection.connected, let peer = connection.peer else {
            throw LoopbackError("connection \(id) isn't connected")
        }
        return peer
    }

    private func post(_ id: Int32, _ event: WebRTCHostEvent) {
        guard var connection = connections[id], !connection.closed else { return }
        if connection.waiting.isEmpty {
            connection.queue.append(event)
        } else {
            connection.waiting.removeFirst().resume(returning: event)
        }
        connections[id] = connection
    }

    private static func connectionID(in description: String) -> Int32? {
        guard let range = description.range(of: "loopback ") else { return nil }
        return Int32(description[range.upperBound...].prefix { $0.isNumber })
    }
}

struct LoopbackError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
