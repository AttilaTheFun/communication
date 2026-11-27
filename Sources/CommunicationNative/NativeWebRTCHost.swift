#if canImport(CWebRTC)
import Communication
import CommunicationCore
import CWebRTC
import Foundation

/// Linux's, Windows' and Android's `WebRTCHost`: libwebrtc through CWebRTC,
/// the C interface over LiveKit's prebuilt static libwebrtc
/// (`Docs/platforms.md`), in the W3C terms `CommunicationCore` speaks. Give
/// it to `HostConnector` to run the shared implementation over real WebRTC.
///
/// Signaling and data channels, as the core is today.
public final class NativeWebRTCHost: WebRTCHost, @unchecked Sendable {
    // `@unchecked`: `connections` and `nextID` are guarded by `lock`;
    // CWebRTC's peers are safe to call from any thread.
    private let lock = NSLock()
    private var connections: [Int32: NativeConnection] = [:]
    private var nextID: Int32 = 1

    public init() {}

    public func create(configuration: String) async throws -> Int32 {
        let wire = try W3C.decode(W3C.Configuration.self, configuration)
        let connection = try NativeConnection(wire)
        return lock.withLock {
            let id = nextID
            nextID += 1
            connections[id] = connection
            return id
        }
    }

    public func createOffer(connection id: Int32, options: String) async throws -> String {
        let options = try W3C.decode(W3C.OfferOptions.self, options)
        let peer = try connection(id).peer
        return try await NativeConnection.description { done, context in
            cw_peer_create_offer(peer, Self.flag(options.iceRestart), Self.flag(options.offerToReceiveAudio),
                                 Self.flag(options.offerToReceiveVideo), Self.flag(options.voiceActivityDetection), done, context)
        }
    }

    public func createAnswer(connection id: Int32, options: String) async throws -> String {
        let options = try W3C.decode(W3C.OfferOptions.self, options)
        let peer = try connection(id).peer
        return try await NativeConnection.description { done, context in
            cw_peer_create_answer(peer, Self.flag(options.iceRestart), Self.flag(options.offerToReceiveAudio),
                                  Self.flag(options.offerToReceiveVideo), Self.flag(options.voiceActivityDetection), done, context)
        }
    }

    public func setLocalDescription(connection id: Int32, description: String) async throws {
        let wire = try W3C.decode(W3C.SessionDescription.self, description)
        let peer = try connection(id).peer
        _ = try await NativeConnection.description { done, context in
            cw_peer_set_local_description(peer, wire.type, wire.sdp, done, context)
        }
    }

    public func setRemoteDescription(connection id: Int32, description: String) async throws {
        let wire = try W3C.decode(W3C.SessionDescription.self, description)
        let peer = try connection(id).peer
        _ = try await NativeConnection.description { done, context in
            cw_peer_set_remote_description(peer, wire.type, wire.sdp, done, context)
        }
    }

    public func localDescription(connection id: Int32) async -> String {
        guard let peer = (try? connection(id))?.peer else { return "" }
        return (try? await NativeConnection.description { done, context in
            cw_peer_local_description(peer, done, context)
        }) ?? ""
    }

    public func addCandidate(connection id: Int32, candidate: String) async throws {
        let wire = try W3C.decode(W3C.ICECandidate.self, candidate)
        let peer = try connection(id).peer
        _ = try await NativeConnection.description { done, context in
            cw_peer_add_candidate(peer, wire.candidate, wire.sdpMid, wire.sdpMLineIndex ?? -1, done, context)
        }
    }

    public func restartICE(connection id: Int32) async {
        guard let peer = (try? connection(id))?.peer else { return }
        cw_peer_restart_ice(peer)
    }

    public func openDataChannel(connection id: Int32, label: String, configuration: String) async throws {
        let wire = try W3C.decode(W3C.DataChannelInit.self, configuration)
        let peer = try connection(id).peer
        var channel = cw_channel_configuration(
            ordered: Self.flag(wire.ordered),
            max_packet_life_time: Int32(clamping: wire.maxPacketLifeTime ?? -1),
            max_retransmits: Int32(clamping: wire.maxRetransmits ?? -1),
            protocol: nil,
            negotiated: Self.flag(wire.negotiated),
            id: wire.id ?? -1
        )
        var error = [CChar](repeating: 0, count: 256)
        guard cw_peer_open_channel(peer, label, &channel, &error, error.count) == 0 else {
            throw CommunicationError(code: .initializationFailed,
                                     message: "Could not open data channel \(label): \(Self.text(error))")
        }
    }

    public func sendText(connection id: Int32, channel: String, text: String) async throws {
        try send(id, channel, Array(text.utf8), binary: false)
    }

    public func sendData(connection id: Int32, channel: String, data: [UInt8]) async throws {
        try send(id, channel, data, binary: true)
    }

    public func nextEvent(connection id: Int32) async throws -> WebRTCHostEvent {
        guard let connection = try? connection(id) else { return WebRTCHostEvent(.closed) }
        return await connection.next()
    }

    public func disconnect(connection id: Int32) async {
        let connection = lock.withLock { connections.removeValue(forKey: id) }
        connection?.close()
    }

    private func send(_ id: Int32, _ label: String, _ bytes: [UInt8], binary: Bool) throws {
        let peer = try connection(id).peer
        let sent = bytes.withUnsafeBufferPointer { buffer in
            cw_peer_send(peer, label, buffer.baseAddress, buffer.count, binary ? 1 : 0)
        }
        guard sent == 0 else {
            throw CommunicationError(code: .invalidState, message: "Could not send on data channel \(label).")
        }
    }

    private func connection(_ id: Int32) throws -> NativeConnection {
        guard let connection = lock.withLock({ connections[id] }) else {
            throw CommunicationError(code: .invalidState, message: "No connection \(id).")
        }
        return connection
    }

    private static func flag(_ value: Bool) -> Int32 { value ? 1 : 0 }

    static func text(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// One CWebRTC peer, and the events it reports, queued until the core pulls
/// them.
private final class NativeConnection: @unchecked Sendable {
    // `@unchecked`: the queue below is guarded by `lock`. CWebRTC calls
    // `onEvent` on libwebrtc's signaling thread, and the core pulls from
    // another.
    private let lock = NSLock()
    private var queue: [WebRTCHostEvent] = []
    private var waiting: [CheckedContinuation<WebRTCHostEvent, Never>] = []
    private var closed = false
    // Set once in init, released in deinit.
    private(set) var peer: OpaquePointer!

    init(_ configuration: W3C.Configuration) throws {
        var error = [CChar](repeating: 0, count: 256)
        let context = Unmanaged.passUnretained(self).toOpaque()
        // The C strings live until cw_peer_create returns, which copies them.
        let made: OpaquePointer? = Self.withServers(configuration.iceServers) { servers in
            var rtc = cw_configuration(
                ice_servers: servers.baseAddress,
                ice_server_count: servers.count,
                relay_only: configuration.iceTransportPolicy == "relay" ? 1 : 0,
                gather_continually: configuration.native.gathersIceContinually ? 1 : 0,
                low_cost_networks: configuration.native.candidateNetworkPolicy == "lowCost" ? 1 : 0
            )
            return cw_peer_create(&rtc, NativeConnection.onEvent, context, &error, error.count)
        }
        guard let made else {
            throw CommunicationError(code: .initializationFailed,
                                     message: "Unable to create a WebRTC peer connection: \(NativeWebRTCHost.text(error))")
        }
        peer = made
    }

    deinit { cw_peer_release(peer) }

    func next() async -> WebRTCHostEvent {
        await withCheckedContinuation { continuation in
            let event: WebRTCHostEvent? = lock.withLock {
                if !queue.isEmpty { return queue.removeFirst() }
                if closed { return WebRTCHostEvent(.closed) }
                waiting.append(continuation)
                return nil
            }
            if let event { continuation.resume(returning: event) }
        }
    }

    func close() {
        cw_peer_close(peer)
    }

    private func post(_ event: WebRTCHostEvent) {
        if event.kind == WebRTCHostEvent.Kind.closed.rawValue {
            let waiters = lock.withLock {
                closed = true
                defer { waiting.removeAll() }
                return waiting
            }
            for waiter in waiters { waiter.resume(returning: event) }
            return
        }
        let waiter: CheckedContinuation<WebRTCHostEvent, Never>? = lock.withLock {
            guard !closed else { return nil }
            if waiting.isEmpty {
                queue.append(event)
                return nil
            }
            return waiting.removeFirst()
        }
        waiter?.resume(returning: event)
    }

    // The context is the connection itself, unretained: cw_peer_release in
    // deinit stops the events before it's gone.
    private static let onEvent: cw_event_fn = { context, kind, channel, text, data, length in
        guard let context else { return }
        let connection = Unmanaged<NativeConnection>.fromOpaque(context).takeUnretainedValue()
        let bytes = data.map { [UInt8](UnsafeBufferPointer(start: $0, count: length)) } ?? []
        connection.post(WebRTCHostEvent(
            kind: kind,
            channel: channel.map { String(cString: $0) } ?? "",
            text: text.map { String(cString: $0) } ?? "",
            data: bytes
        ))
    }

    /// Runs a CWebRTC call that ends with a `cw_result_fn`, and gives its
    /// description as `RTCSessionDescriptionInit` JSON ("" for a call that
    /// makes none).
    static func description(
        _ call: (cw_result_fn, UnsafeMutableRawPointer) -> Void
    ) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            let box = Unmanaged.passRetained(ResultBox(continuation)).toOpaque()
            call(Self.onResult, box)
        }
    }

    // The box is retained for the call and released here: CWebRTC calls
    // every cw_result_fn exactly once.
    private static let onResult: cw_result_fn = { context, error, type, sdp in
        guard let context else { return }
        let box = Unmanaged<ResultBox>.fromOpaque(context).takeRetainedValue()
        if let error {
            box.continuation.resume(throwing: CommunicationError(code: .webRTCOperationFailed, message: String(cString: error)))
        } else if let type, let sdp {
            box.continuation.resume(returning: W3C.json(W3C.SessionDescription(type: String(cString: type), sdp: String(cString: sdp))))
        } else {
            box.continuation.resume(returning: "")
        }
    }

    private final class ResultBox {
        let continuation: CheckedContinuation<String, any Error>
        init(_ continuation: CheckedContinuation<String, any Error>) { self.continuation = continuation }
    }

    /// The ICE servers as `cw_ice_server`s, their strings alive for `body`.
    private static func withServers<T>(_ servers: [W3C.Configuration.ICEServer],
                                       _ body: (UnsafeBufferPointer<cw_ice_server>) -> T) -> T {
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func copy(_ string: String?) -> UnsafePointer<CChar>? {
            guard let string, let made = strdup(string) else { return nil }
            owned.append(made)
            return UnsafePointer(made)
        }
        var urlLists: [UnsafeMutablePointer<UnsafePointer<CChar>?>] = []
        defer { urlLists.forEach { $0.deallocate() } }
        let made = servers.map { server -> cw_ice_server in
            let urls = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: max(server.urls.count, 1))
            urlLists.append(urls)
            for (index, url) in server.urls.enumerated() { urls[index] = copy(url) }
            return cw_ice_server(urls: urls, url_count: server.urls.count,
                                 username: copy(server.username), credential: copy(server.credential))
        }
        return made.withUnsafeBufferPointer(body)
    }
}
#endif
