#if canImport(LiveKitWebRTC)
import Foundation

import Communication

@preconcurrency internal import LiveKitWebRTC

/// Internal owner of the raw WebRTC peer connection: negotiation, ICE,
/// data channels. Media lives in a separate package that reaches the raw
final class PeerConnectionCore: @unchecked Sendable {
    /// Serializes calls into the WebRTC peer connection.
    private let queue = DispatchQueue(label: "Communication.PeerConnection")

    /// The process-wide factory (`WebRTCRuntime`), shared with media devices so
    /// their tracks can be added to any connection.
    private let factory: LKRTCPeerConnectionFactory

    /// The raw WebRTC peer connection.
    private let peerConnection: LKRTCPeerConnection

    /// Delegate retained for the lifetime of the peer connection.
    private let delegate: PeerConnectionDelegate

    /// Pipe used to publish delegate events as an async stream.
    private let pipe = AsyncPipe<CommunicationEvent>()

    /// The connection's data channels, however they came into existence.
    private let dataChannels: DataChannelRegistry

    /// Events emitted by the WebRTC delegate.
    var events: AsyncStream<CommunicationEvent> {
        pipe.stream
    }

    /// Creates the underlying WebRTC peer connection.
    ///
    /// - Parameters:
    ///   - configuration: Swift configuration converted to `LKRTCConfiguration`.
    /// The connection's own audio device when the application plays and
    /// captures its audio (`CommunicationAudioPlayback.application`).
    let applicationAudio: ApplicationAudioDevice?

    init(configuration: CommunicationConfiguration) throws {
        let factory: LKRTCPeerConnectionFactory
        if configuration.audioPlayback == .application {
            // A factory of its own, so the device's playout is this peer alone.
            let device = ApplicationAudioDevice()
            factory = try WebRTCRuntime.shared.makeFactory(audioDevice: device)
            device.factory = factory
            applicationAudio = device
        } else {
            factory = try WebRTCRuntime.shared.factory
            applicationAudio = nil
        }
        let dataChannels = DataChannelRegistry { [pipe] event in
            pipe.yield(event)
        }
        let delegate = PeerConnectionDelegate(
            emit: { [pipe] event in pipe.yield(event) },
            // A channel the remote opened arrives here; adopting it makes the
            // two sides symmetric from the caller's point of view.
            adoptDataChannel: { [dataChannels] channel in dataChannels.adopt(channel) }
        )
        self.dataChannels = dataChannels

        let peerConnection = factory.peerConnection(
            with: configuration.rtcConfiguration,
            constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: delegate
        )

        guard let peerConnection else {
            throw CommunicationError(
                code: .initializationFailed,
                message: "Unable to create a WebRTC peer connection."
            )
        }

        self.factory = factory
        self.delegate = delegate
        self.peerConnection = peerConnection
    }

    // MARK: - Media

    func addTrack(_ track: any CommunicationMediaStreamTrack, streamIDs: [String]) throws -> any CommunicationRtpSender {
        guard let raw = (track as? WebRTCMediaTrack)?.raw else {
            throw CommunicationError(code: .invalidState, message: "track is not from this backend")
        }
        return try queue.sync {
            guard let sender = peerConnection.add(raw, streamIds: streamIDs) else {
                throw CommunicationError(code: .invalidState, message: "could not add track")
            }
            return WebRTCRtpSender(sender)
        }
    }

    func removeTrack(_ sender: any CommunicationRtpSender) throws {
        guard let raw = (sender as? WebRTCRtpSender)?.raw else {
            throw CommunicationError(code: .invalidState, message: "sender is not from this backend")
        }
        let removed = queue.sync { peerConnection.removeTrack(raw) }
        guard removed else { throw CommunicationError(code: .invalidState, message: "could not remove track") }
    }

    func addTransceiver(kind: CommunicationMediaKind, direction: CommunicationTransceiverDirection) throws -> any CommunicationRtpTransceiver {
        let initial = LKRTCRtpTransceiverInit()
        initial.direction = direction.rtcDirection
        return try queue.sync {
            guard let transceiver = peerConnection.addTransceiver(of: kind.rtcMediaType, init: initial) else {
                throw CommunicationError(code: .invalidState, message: "could not add transceiver")
            }
            return WebRTCRtpTransceiver(transceiver)
        }
    }

    var transceivers: [any CommunicationRtpTransceiver] { queue.sync { peerConnection.transceivers.map(WebRTCRtpTransceiver.init) } }
    var senders: [any CommunicationRtpSender] { queue.sync { peerConnection.senders.map(WebRTCRtpSender.init) } }
    var receivers: [any CommunicationRtpReceiver] { queue.sync { peerConnection.receivers.map(WebRTCRtpReceiver.init) } }

    /// Closes WebRTC resources and finishes event delivery.
    deinit {
        peerConnection.close()
        pipe.finish()
    }

    /// Creates an SDP offer on the WebRTC queue.
    func offer(options: CommunicationOfferOptions) async throws -> CommunicationSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [peerConnection] in
                peerConnection.offer(for: options.rtcConstraints) { description, error in
                    continuation.resume(with: Self.result(description: description, error: error))
                }
            }
        }
    }

    /// Creates an SDP answer on the WebRTC queue.
    func answer(options: CommunicationAnswerOptions) async throws -> CommunicationSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [peerConnection] in
                peerConnection.answer(for: options.rtcConstraints) { description, error in
                    continuation.resume(with: Self.result(description: description, error: error))
                }
            }
        }
    }

    /// Applies a local description on the WebRTC queue.
    func setLocalDescription(_ description: CommunicationSessionDescription) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [peerConnection] in
                peerConnection.setLocalDescription(description.rtcSessionDescription) { error in
                    continuation.resume(with: Self.result(error: error))
                }
            }
        }
    }

    /// Applies a remote description on the WebRTC queue.
    func setRemoteDescription(_ description: CommunicationSessionDescription) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [peerConnection] in
                peerConnection.setRemoteDescription(description.rtcSessionDescription) { error in
                    continuation.resume(with: Self.result(error: error))
                }
            }
        }
    }

    /// Adds a remote ICE candidate on the WebRTC queue.
    func addRemoteCandidate(_ candidate: CommunicationICECandidate) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [peerConnection] in
                peerConnection.add(candidate.rtcIceCandidate) { error in
                    continuation.resume(with: Self.result(error: error))
                }
            }
        }
    }

    /// Requests ICE restart on the WebRTC queue.
    func restartICE() {
        queue.async { [peerConnection] in
            peerConnection.restartIce()
        }
    }

    /// Closes the peer connection on the WebRTC queue and finishes events.
    /// The local description as it currently stands.
    ///
    /// Worth reading *after* gathering finishes rather than taking what
    /// `offer`/`answer` returned: the candidates are added to it as they are
    /// discovered, and a description captured before then describes a peer
    /// nobody can reach.
    var localDescription: CommunicationSessionDescription? {
        queue.sync {
            peerConnection.localDescription.map(CommunicationSessionDescription.init)
        }
    }

    /// How far ICE gathering has got.
    var iceGatheringState: CommunicationICEGatheringState {
        queue.sync { CommunicationICEGatheringState(peerConnection.iceGatheringState) }
    }

    // MARK: - Data channels

    /// Opens a channel, or returns the existing one with that label.
    func openDataChannel(
        label: String,
        configuration: CommunicationDataChannelConfiguration
    ) throws {
        if dataChannels.channel(labeled: label) != nil { return }
        let channel = queue.sync {
            peerConnection.dataChannel(
                forLabel: label,
                configuration: configuration.rtcConfiguration
            )
        }
        guard let channel else {
            throw CommunicationError(
                code: .initializationFailed,
                message: "could not open data channel \(label)"
            )
        }
        dataChannels.adopt(channel)
    }

    /// Sends on the named channel, or on the only open one when unnamed.
    func send(_ message: CommunicationDataChannelMessage, label: String?) throws {
        let channel = label.flatMap { dataChannels.channel(labeled: $0) }
            ?? dataChannels.soleOpenChannel()
        guard let channel, channel.readyState == .open else {
            throw CommunicationError(
                code: .invalidState,
                message: "no open data channel\(label.map { " labelled \($0)" } ?? "")"
            )
        }
        let buffer: LKRTCDataBuffer
        switch message {
        case let .text(text):
            buffer = LKRTCDataBuffer(data: Data(text.utf8), isBinary: false)
        case let .binary(data):
            buffer = LKRTCDataBuffer(data: data, isBinary: true)
        }
        _ = queue.sync { channel.sendData(buffer) }
    }

    func close() {
        dataChannels.closeAll()
        queue.async { [peerConnection, pipe] in
            peerConnection.close()
            pipe.finish()
        }
    }

    /// Converts WebRTC's optional description/error callback into a Swift result.
    private static func result(
        description: LKRTCSessionDescription?,
        error: (any Error)?
    ) -> Result<CommunicationSessionDescription, any Error> {
        if let error {
            return .failure(CommunicationError(
                code: .webRTCOperationFailed,
                message: error.localizedDescription
            ))
        }

        guard let description else {
            return .failure(CommunicationError(
                code: .webRTCOperationFailed,
                message: "WebRTC completed without returning a session description."
            ))
        }

        return .success(CommunicationSessionDescription(description))
    }

    /// Converts a WebRTC completion callback error into a Swift result.
    private static func result(error: (any Error)?) -> Result<Void, any Error> {
        if let error {
            return .failure(CommunicationError(
                code: .webRTCOperationFailed,
                message: error.localizedDescription
            ))
        }

        return .success(())
    }
}

/// Lets the delegate, created before the core, reach the core afterwards.
#endif
