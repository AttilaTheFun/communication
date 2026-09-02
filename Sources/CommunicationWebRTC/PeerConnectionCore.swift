import Foundation

import Communication

@preconcurrency internal import WebRTC

/// Internal owner of the raw WebRTC peer connection and related audio state.
final class PeerConnectionCore: @unchecked Sendable {
    /// Serializes calls into the WebRTC peer connection.
    private let queue = DispatchQueue(label: "Communication.PeerConnection")

    /// Instance-owned WebRTC SSL initialization lifetime.
    private let sslRuntime: WebRTCSSLRuntime

    /// Factory that creates peer connections, sources, and tracks.
    private let factory: RTCPeerConnectionFactory

    /// The raw WebRTC peer connection.
    private let peerConnection: RTCPeerConnection

    /// Delegate retained for the lifetime of the peer connection.
    private let delegate: PeerConnectionDelegate

    /// The local audio source, if this connection owns one. Mutable because
    /// a call can begin and end mid-connection: the audio track is added and
    /// removed on the live peer connection rather than fixed at setup.
    private var localAudioSource: RTCAudioSource?

    /// The local outgoing audio track, if this connection owns one.
    private var localAudioTrack: RTCAudioTrack?

    /// The RTP sender for the local audio track, kept so the track can be
    /// removed again when the call ends.
    private var localAudioSender: RTCRtpSender?

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
    ///   - configuration: Swift configuration converted to `RTCConfiguration`.
    ///   - createsLocalAudioTrack: Whether to create and attach a local audio track.
    init(
        configuration: CommunicationConfiguration,
        createsLocalAudioTrack: Bool = true
    ) throws {
        let sslRuntime = try WebRTCSSLRuntime()

        let factory = RTCPeerConnectionFactory()
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
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: delegate
        )

        guard let peerConnection else {
            throw CommunicationError(
                code: .initializationFailed,
                message: "Unable to create a WebRTC peer connection."
            )
        }

        self.sslRuntime = sslRuntime
        self.factory = factory
        self.delegate = delegate
        self.peerConnection = peerConnection

        if createsLocalAudioTrack {
            guard addLocalAudioTrack() else {
                peerConnection.close()
                throw CommunicationError(
                    code: .initializationFailed,
                    message: "Unable to add a local audio track to the WebRTC peer connection."
                )
            }
        }
    }

    // MARK: - Mid-call audio
    //
    // Audio is added and removed on the live connection, so a data-only
    // session can become a call and end again without tearing down the peer
    // connection or the chat that rides it. Each change alters the set of
    // m-lines, so the caller must renegotiate afterwards (offer/answer).

    /// Adds a local microphone track if there isn't one already. Returns
    /// whether a track is now present. Call `offer`/`answer` afterwards — the
    /// SDP changed.
    @discardableResult
    func addLocalAudioTrack() -> Bool {
        queue.sync {
            if localAudioTrack != nil { return true }
            let audioSource = factory.audioSource(
                with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            )
            let audioTrack = factory.audioTrack(
                with: audioSource,
                trackId: "communication-audio-\(UUID().uuidString)"
            )
            guard let sender = peerConnection.add(audioTrack, streamIds: ["communication"]) else {
                return false
            }
            localAudioSource = audioSource
            localAudioTrack = audioTrack
            localAudioSender = sender
            return true
        }
    }

    /// Removes the local microphone track if present. Renegotiate afterwards.
    func removeLocalAudioTrack() {
        queue.sync {
            if let sender = localAudioSender {
                peerConnection.removeTrack(sender)
            }
            localAudioSender = nil
            localAudioTrack = nil
            localAudioSource = nil
        }
    }

    /// Whether a call is currently active on this connection.
    var hasLocalAudio: Bool {
        queue.sync { localAudioTrack != nil }
    }

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
        let buffer: RTCDataBuffer
        switch message {
        case let .text(text):
            buffer = RTCDataBuffer(data: Data(text.utf8), isBinary: false)
        case let .binary(data):
            buffer = RTCDataBuffer(data: data, isBinary: true)
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

    /// Enables or disables the local outgoing audio track. Reads the track
    /// on the queue rather than capturing it, so it affects whatever track is
    /// attached now — a call may have started after this object was created.
    func setLocalAudioMuted(_ muted: Bool) {
        queue.async { [self] in
            localAudioTrack?.isEnabled = !muted
        }
    }

    /// Maps `0...1` gain into WebRTC's audio source volume range.
    func setLocalAudioGain(_ gain: Float) {
        let volume = Double(Self.clampUnit(gain)) * 10
        queue.async { [self] in
            localAudioSource?.volume = volume
        }
    }

    /// Enables or disables all currently attached remote audio tracks.
    func setRemoteAudioPlaybackMuted(_ muted: Bool) {
        queue.async { [peerConnection] in
            for audioTrack in Self.remoteAudioTracks(in: peerConnection) {
                audioTrack.isEnabled = !muted
            }
        }
    }

    /// Maps `0...1` playback volume into WebRTC remote audio source volume.
    func setRemoteAudioPlaybackVolume(_ volume: Float) {
        let rtcVolume = Double(Self.clampUnit(volume)) * 10
        queue.async { [peerConnection] in
            for audioTrack in Self.remoteAudioTracks(in: peerConnection) {
                audioTrack.source.volume = rtcVolume
            }
        }
    }

    /// Converts WebRTC's optional description/error callback into a Swift result.
    private static func result(
        description: RTCSessionDescription?,
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

    /// Returns the remote audio tracks currently attached to the peer connection.
    private static func remoteAudioTracks(in peerConnection: RTCPeerConnection) -> [RTCAudioTrack] {
        peerConnection.receivers.compactMap { receiver in
            receiver.track as? RTCAudioTrack
        }
    }

    /// Clamps a normalized audio value into `0...1`.
    private static func clampUnit(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}

/// Instance-scoped owner for WebRTC SSL initialization and cleanup.
private final class WebRTCSSLRuntime {
    /// Initializes the WebRTC SSL adapter for this runtime instance.
    init() throws {
        guard RTCInitializeSSL() else {
            throw CommunicationError(
                code: .initializationFailed,
                message: "Unable to initialize WebRTC SSL."
            )
        }
    }

    /// Cleans up the WebRTC SSL adapter when this runtime instance is released.
    deinit {
        _ = RTCCleanupSSL()
    }
}
