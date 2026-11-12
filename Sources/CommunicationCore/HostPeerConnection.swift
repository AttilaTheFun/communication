import Communication
import Foundation

/// `CommunicationPeerConnection` over a `WebRTCHost`: the one
/// implementation every platform shares. The host does WebRTC; this keeps
/// the API's state and events, and maps between the API and the host's W3C
/// values.
///
/// Media (tracks, senders, receivers, transceivers) isn't in the host yet.
/// Those calls throw `.unsupportedOperation` until it is.
public actor HostPeerConnection: CommunicationPeerConnection {
    public nonisolated let events: AsyncStream<CommunicationEvent>

    private let continuation: AsyncStream<CommunicationEvent>.Continuation
    private let host: any WebRTCHost
    /// The host's connection, created as the connector hands this out. Every
    /// call waits for it.
    private let created: Task<Int32, any Error>
    private var pump: Task<Void, Never>?
    private var finished = false
    private var gathering: CommunicationICEGatheringState = .fresh
    /// The data channels by label, in the state their last event reported.
    private var channels: [String: CommunicationDataChannelState] = [:]

    init(host: any WebRTCHost, configuration: CommunicationConfiguration) {
        self.host = host
        let wire = W3C.json(W3C.configuration(configuration))
        created = Task { try await host.create(configuration: wire) }
        (events, continuation) = AsyncStream.makeStream(of: CommunicationEvent.self)
    }

    // MARK: State

    public var localDescription: CommunicationSessionDescription? {
        get async {
            guard let id = try? await created.value else { return nil }
            let json = await host.localDescription(connection: id)
            guard !json.isEmpty, let wire = try? W3C.decode(W3C.SessionDescription.self, json) else { return nil }
            return try? W3C.sessionDescription(wire)
        }
    }

    public var iceGatheringState: CommunicationICEGatheringState {
        get async { gathering }
    }

    // MARK: Data channels

    public func openDataChannel(label: String, configuration: CommunicationDataChannelConfiguration) async throws {
        let id = try await connection()
        try await call {
            try await host.openDataChannel(connection: id, label: label, configuration: W3C.json(W3C.dataChannelInit(configuration)))
        }
        if channels[label] == nil { channels[label] = .connecting }
    }

    public func send(text: String, on label: String?) async throws {
        let id = try await connection()
        let channel = try openChannel(label)
        try await call { try await host.sendText(connection: id, channel: channel, text: text) }
    }

    public func send(data: Data, on label: String?) async throws {
        let id = try await connection()
        let channel = try openChannel(label)
        try await call { try await host.sendData(connection: id, channel: channel, data: [UInt8](data)) }
    }

    /// The channel to send on: the one named, or the sole open one.
    private func openChannel(_ label: String?) throws -> String {
        if let label {
            guard channels[label] == .open else {
                throw CommunicationError(code: .invalidState, message: "Data channel \(label) isn't open.")
            }
            return label
        }
        let open = channels.filter { $0.value == .open }.map(\.key)
        guard open.count == 1, let only = open.first else {
            throw CommunicationError(
                code: .invalidState,
                message: open.isEmpty ? "No data channel is open." : "\(open.count) data channels are open; name one."
            )
        }
        return only
    }

    // MARK: Offer, answer and ICE

    public func offer(options: CommunicationOfferOptions) async throws -> CommunicationSessionDescription {
        let id = try await connection()
        let json = try await call { try await host.createOffer(connection: id, options: W3C.json(W3C.offerOptions(options))) }
        return try W3C.sessionDescription(W3C.decode(W3C.SessionDescription.self, json))
    }

    public func answer(options: CommunicationAnswerOptions) async throws -> CommunicationSessionDescription {
        let id = try await connection()
        let json = try await call { try await host.createAnswer(connection: id, options: W3C.json(W3C.offerOptions(options))) }
        return try W3C.sessionDescription(W3C.decode(W3C.SessionDescription.self, json))
    }

    public func setLocalDescription(_ description: CommunicationSessionDescription) async throws {
        let id = try await connection()
        try await call { try await host.setLocalDescription(connection: id, description: W3C.json(W3C.sessionDescription(description))) }
    }

    public func setRemoteDescription(_ description: CommunicationSessionDescription) async throws {
        let id = try await connection()
        try await call { try await host.setRemoteDescription(connection: id, description: W3C.json(W3C.sessionDescription(description))) }
    }

    public func addRemoteCandidate(_ candidate: CommunicationICECandidate) async throws {
        let id = try await connection()
        try await call { try await host.addCandidate(connection: id, candidate: W3C.json(W3C.candidate(candidate))) }
    }

    public func restartICE() async {
        guard let id = try? await connection() else { return }
        await host.restartICE(connection: id)
    }

    public func close() async {
        if let id = try? await created.value {
            startPump()
            await host.disconnect(connection: id)
            // The host's last events (the connection's closed state, then
            // `.closed`) still reach the stream before it ends.
            await pump?.value
        }
        finish()
    }

    deinit {
        // A connection the caller let go of closes, as WebRTC's own do.
        let host = host
        let created = created
        Task {
            if let id = try? await created.value { await host.disconnect(connection: id) }
        }
        pump?.cancel()
        continuation.finish()
    }

    // MARK: Media (not in the host yet)

    public func addTrack(_ track: any CommunicationMediaStreamTrack, streamIDs: [String]) async throws -> any CommunicationRtpSender {
        throw Self.noMedia
    }

    public func removeTrack(_ sender: any CommunicationRtpSender) async throws {
        throw Self.noMedia
    }

    public func addTransceiver(kind: CommunicationMediaKind, direction: CommunicationTransceiverDirection) async throws -> any CommunicationRtpTransceiver {
        throw Self.noMedia
    }

    public var transceivers: [any CommunicationRtpTransceiver] { get async { [] } }
    public var senders: [any CommunicationRtpSender] { get async { [] } }
    public var receivers: [any CommunicationRtpReceiver] { get async { [] } }

    static let noMedia = CommunicationError(code: .unsupportedOperation, message: "Media isn't available on this platform yet.")

    // MARK: The host's events

    /// The host's connection id, starting the event pump the first time.
    private func connection() async throws -> Int32 {
        startPump()
        do {
            return try await created.value
        } catch let error as CommunicationError {
            throw error
        } catch {
            throw CommunicationError(code: .initializationFailed, message: "\(error)")
        }
    }

    /// Pulls the host's events until it reports the connection closed.
    func startPump() {
        guard pump == nil, !finished else { return }
        pump = Task { [weak self, host, created] in
            guard let id = try? await created.value else {
                await self?.finish()
                return
            }
            while !Task.isCancelled {
                guard let event = try? await host.nextEvent(connection: id) else { break }
                guard let self, await self.receive(event) else { return }
            }
            await self?.finish()
        }
    }

    /// Turns one host event into the API's; false once the connection closed.
    private func receive(_ event: WebRTCHostEvent) -> Bool {
        guard !finished, let kind = WebRTCHostEvent.Kind(rawValue: event.kind) else { return !finished }
        switch kind {
        case .closed:
            finish()
            return false
        case .signalingState:
            emit(.signalingStateChanged(W3C.signalingState(event.text)))
        case .iceConnectionState:
            emit(.iceConnectionStateChanged(W3C.iceConnectionState(event.text)))
        case .connectionState:
            emit(.connectionStateChanged(W3C.connectionState(event.text)))
        case .iceGatheringState:
            gathering = W3C.iceGatheringState(event.text)
            emit(.iceGatheringStateChanged(gathering))
        case .candidate:
            if let wire = try? W3C.decode(W3C.ICECandidate.self, event.text) {
                emit(.localCandidateDiscovered(W3C.candidate(wire)))
            }
        case .candidatesRemoved:
            if let wire = try? W3C.decode([W3C.ICECandidate].self, event.text) {
                emit(.localCandidatesRemoved(wire.map(W3C.candidate)))
            }
        case .negotiationNeeded:
            emit(.negotiationNeeded)
        case .channelState:
            let state = W3C.dataChannelState(event.text)
            let previous = channels[event.channel]
            channels[event.channel] = state
            if state == .open, previous != .open { emit(.dataChannelOpened(label: event.channel)) }
            emit(.dataChannelStateChanged(label: event.channel, state: state))
        case .textMessage:
            emit(.dataChannelMessage(label: event.channel, message: .text(event.text)))
        case .dataMessage:
            emit(.dataChannelMessage(label: event.channel, message: .binary(Data(event.data))))
        }
        return true
    }

    private func emit(_ event: CommunicationEvent) {
        continuation.yield(event)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        pump?.cancel()
        continuation.finish()
    }

    /// Runs a host call, reporting its failures as the API's errors.
    private func call<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as CommunicationError {
            throw error
        } catch {
            throw CommunicationError(code: .webRTCOperationFailed, message: "\(error)")
        }
    }
}
