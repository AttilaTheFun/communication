#if canImport(LiveKitWebRTC)
import Communication
import CommunicationCore
import Foundation
@preconcurrency internal import LiveKitWebRTC

/// The Apple platforms' `WebRTCHost`: LiveKit's build of libwebrtc, in the
/// W3C terms `CommunicationCore` speaks. Give it to `HostConnector` to run
/// the shared implementation over real WebRTC.
///
/// Signaling and data channels only, as the core is today; media stays with
/// `WebRTCConnector` until the host interface has it.
public final class LiveKitWebRTCHost: WebRTCHost, @unchecked Sendable {
    // `@unchecked`: `connections` and `nextID` are guarded by `lock`; the
    // peer connections themselves are libwebrtc's, safe from any thread.
    private let lock = NSLock()
    private var connections: [Int32: HostedConnection] = [:]
    private var nextID: Int32 = 1

    public init() {}

    public func create(configuration: String) async throws -> Int32 {
        let wire = try W3C.decode(W3C.Configuration.self, configuration)
        let hosted = HostedConnection()
        let peerConnection = try WebRTCRuntime.shared.factory.peerConnection(
            with: W3C.configuration(wire).rtcConfiguration,
            constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: hosted
        )
        guard let peerConnection else {
            throw CommunicationError(code: .initializationFailed, message: "Unable to create a WebRTC peer connection.")
        }
        hosted.peerConnection = peerConnection
        return lock.withLock {
            let id = nextID
            nextID += 1
            connections[id] = hosted
            return id
        }
    }

    public func createOffer(connection id: Int32, options: String) async throws -> String {
        let constraints = W3C.offerOptions(try W3C.decode(W3C.OfferOptions.self, options)).rtcConstraints
        let peerConnection = try hosted(id).peerConnection
        // Converted to W3C JSON in the callback: only a String crosses threads.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            peerConnection?.offer(for: constraints) { description, error in
                continuation.resume(with: Self.result(description, error).map {
                    W3C.json(W3C.sessionDescription(CommunicationSessionDescription($0)))
                })
            }
        }
    }

    public func createAnswer(connection id: Int32, options: String) async throws -> String {
        let constraints = W3C.offerOptions(try W3C.decode(W3C.OfferOptions.self, options)).rtcConstraints
        let peerConnection = try hosted(id).peerConnection
        // Converted to W3C JSON in the callback: only a String crosses threads.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            peerConnection?.answer(for: constraints) { description, error in
                continuation.resume(with: Self.result(description, error).map {
                    W3C.json(W3C.sessionDescription(CommunicationSessionDescription($0)))
                })
            }
        }
    }

    public func setLocalDescription(connection id: Int32, description: String) async throws {
        let rtc = try W3C.sessionDescription(W3C.decode(W3C.SessionDescription.self, description)).rtcSessionDescription
        let peerConnection = try hosted(id).peerConnection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            peerConnection?.setLocalDescription(rtc) { error in continuation.resume(with: Self.result(error)) }
        }
    }

    public func setRemoteDescription(connection id: Int32, description: String) async throws {
        let rtc = try W3C.sessionDescription(W3C.decode(W3C.SessionDescription.self, description)).rtcSessionDescription
        let peerConnection = try hosted(id).peerConnection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            peerConnection?.setRemoteDescription(rtc) { error in continuation.resume(with: Self.result(error)) }
        }
    }

    public func localDescription(connection id: Int32) async -> String {
        guard let description = (try? hosted(id))?.peerConnection?.localDescription else { return "" }
        return W3C.json(W3C.sessionDescription(CommunicationSessionDescription(description)))
    }

    public func addCandidate(connection id: Int32, candidate: String) async throws {
        let rtc = W3C.candidate(try W3C.decode(W3C.ICECandidate.self, candidate)).rtcIceCandidate
        let peerConnection = try hosted(id).peerConnection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            peerConnection?.add(rtc) { error in continuation.resume(with: Self.result(error)) }
        }
    }

    public func restartICE(connection id: Int32) async {
        (try? hosted(id))?.peerConnection?.restartIce()
    }

    public func openDataChannel(connection id: Int32, label: String, configuration: String) async throws {
        let hosted = try hosted(id)
        let rtc = W3C.dataChannelConfiguration(try W3C.decode(W3C.DataChannelInit.self, configuration)).rtcConfiguration
        guard let channel = hosted.peerConnection?.dataChannel(forLabel: label, configuration: rtc) else {
            throw CommunicationError(code: .initializationFailed, message: "Could not open data channel \(label).")
        }
        hosted.adopt(channel)
    }

    public func sendText(connection id: Int32, channel: String, text: String) async throws {
        try hosted(id).send(LKRTCDataBuffer(data: Data(text.utf8), isBinary: false), on: channel)
    }

    public func sendData(connection id: Int32, channel: String, data: [UInt8]) async throws {
        try hosted(id).send(LKRTCDataBuffer(data: Data(data), isBinary: true), on: channel)
    }

    public func nextEvent(connection id: Int32) async throws -> WebRTCHostEvent {
        guard let hosted = try? hosted(id) else { return WebRTCHostEvent(.closed) }
        return await hosted.next()
    }

    public func disconnect(connection id: Int32) async {
        let hosted = lock.withLock { connections.removeValue(forKey: id) }
        hosted?.close()
    }

    private func hosted(_ id: Int32) throws -> HostedConnection {
        guard let hosted = lock.withLock({ connections[id] }) else {
            throw CommunicationError(code: .invalidState, message: "No connection \(id).")
        }
        return hosted
    }

    private static func result(_ description: LKRTCSessionDescription?, _ error: (any Error)?) -> Result<LKRTCSessionDescription, any Error> {
        if let error { return .failure(CommunicationError(code: .webRTCOperationFailed, message: error.localizedDescription)) }
        guard let description else {
            return .failure(CommunicationError(code: .webRTCOperationFailed, message: "WebRTC produced no session description."))
        }
        return .success(description)
    }

    private static func result(_ error: (any Error)?) -> Result<Void, any Error> {
        error.map { .failure(CommunicationError(code: .webRTCOperationFailed, message: $0.localizedDescription)) } ?? .success(())
    }
}

/// One connection's peer connection, its data channels, and the events its
/// delegates report, queued until the core pulls them.
private final class HostedConnection: NSObject, LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate, @unchecked Sendable {
    // `@unchecked`: everything below is guarded by `lock`. libwebrtc calls
    // the delegates on its own threads, and the core pulls from another.
    private let lock = NSLock()
    private var queue: [WebRTCHostEvent] = []
    private var waiting: [CheckedContinuation<WebRTCHostEvent, Never>] = []
    private var closed = false
    private var channels: [String: LKRTCDataChannel] = [:]
    private var connection: LKRTCPeerConnection?

    var peerConnection: LKRTCPeerConnection? {
        get { lock.withLock { connection } }
        set { lock.withLock { connection = newValue } }
    }

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

    private func post(_ event: WebRTCHostEvent) {
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

    func adopt(_ channel: LKRTCDataChannel) {
        lock.withLock { channels[channel.label] = channel }
        channel.delegate = self
        post(WebRTCHostEvent(.channelState, channel: channel.label, text: Self.name(channel.readyState)))
    }

    func send(_ buffer: LKRTCDataBuffer, on label: String) throws {
        guard let channel = lock.withLock({ channels[label] }), channel.sendData(buffer) else {
            throw CommunicationError(code: .invalidState, message: "Could not send on data channel \(label).")
        }
    }

    func close() {
        let (connection, channels) = lock.withLock { (self.connection, Array(self.channels.values)) }
        for channel in channels { channel.close() }
        connection?.close()
        post(WebRTCHostEvent(.connectionState, text: "closed"))
        let waiters = lock.withLock {
            closed = true
            defer { waiting.removeAll() }
            return waiting
        }
        for waiter in waiters { waiter.resume(returning: WebRTCHostEvent(.closed)) }
    }

    private static func name(_ state: LKRTCDataChannelState) -> String {
        switch state {
        case .connecting: "connecting"
        case .open: "open"
        case .closing: "closing"
        case .closed: "closed"
        @unknown default: "closed"
        }
    }

    // MARK: LKRTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {
        post(WebRTCHostEvent(.signalingState, text: W3C.name(CommunicationSignalingState(stateChanged))))
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {
        post(WebRTCHostEvent(.negotiationNeeded))
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        post(WebRTCHostEvent(.iceConnectionState, text: W3C.name(CommunicationICEConnectionState(newState))))
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        post(WebRTCHostEvent(.iceGatheringState, text: W3C.name(CommunicationICEGatheringState(newState))))
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        post(WebRTCHostEvent(.connectionState, text: W3C.name(CommunicationConnectionState(newState))))
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        post(WebRTCHostEvent(.candidate, text: W3C.json(W3C.candidate(CommunicationICECandidate(candidate)))))
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {
        let removed = candidates.map { W3C.candidate(CommunicationICECandidate($0)) }
        post(WebRTCHostEvent(.candidatesRemoved, text: W3C.json(removed)))
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        adopt(dataChannel)
    }

    // MARK: LKRTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        post(WebRTCHostEvent(.channelState, channel: dataChannel.label, text: Self.name(dataChannel.readyState)))
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        if buffer.isBinary {
            post(WebRTCHostEvent(.dataMessage, channel: dataChannel.label, data: [UInt8](buffer.data)))
        } else {
            post(WebRTCHostEvent(.textMessage, channel: dataChannel.label, text: String(decoding: buffer.data, as: UTF8.self)))
        }
    }
}
#endif
