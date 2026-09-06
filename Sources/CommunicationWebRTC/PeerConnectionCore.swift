import Foundation

import Communication

@preconcurrency internal import WebRTC

/// Internal owner of the raw WebRTC peer connection: negotiation, ICE,
/// data channels. Media lives in a separate package that reaches the raw
/// connection through `withUnderlying` and hears remote tracks through
/// `remoteTrackHandler`.
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

    /// Called with each remote track the peer adds, for the media package.
    private var remoteTrackHandler: (@Sendable (RTCMediaStreamTrack) -> Void)?

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
    init(configuration: CommunicationConfiguration) throws {
        let sslRuntime = try WebRTCSSLRuntime()

        let factory = RTCPeerConnectionFactory()
        let dataChannels = DataChannelRegistry { [pipe] event in
            pipe.yield(event)
        }
        // The delegate exists before the core does; the box lets it reach
        // the core once there is one.
        let remoteTrackBox = RemoteTrackBox()
        let delegate = PeerConnectionDelegate(
            emit: { [pipe] event in pipe.yield(event) },
            // A channel the remote opened arrives here; adopting it makes the
            // two sides symmetric from the caller's point of view.
            adoptDataChannel: { [dataChannels] channel in dataChannels.adopt(channel) },
            adoptRemoteTrack: { track in remoteTrackBox.handler?(track) }
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
        remoteTrackBox.handler = { [weak self] track in self?.adoptRemoteTrack(track) }
    }

    // MARK: - Media escape hatch

    /// Runs `body` on the connection's serial queue with the raw peer
    /// connection and factory. The media package adds and removes tracks
    /// here; nothing in this package interprets them.
    func withUnderlying<T>(_ body: (RTCPeerConnection, RTCPeerConnectionFactory) throws -> T) rethrows -> T {
        try queue.sync { try body(peerConnection, factory) }
    }

    func setRemoteTrackHandler(_ handler: (@Sendable (RTCMediaStreamTrack) -> Void)?) {
        queue.sync { remoteTrackHandler = handler }
    }

    private func adoptRemoteTrack(_ track: RTCMediaStreamTrack) {
        let handler = queue.sync { remoteTrackHandler }
        handler?(track)
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
}

/// Lets the delegate, created before the core, reach the core afterwards.
private final class RemoteTrackBox: @unchecked Sendable {
    var handler: ((RTCMediaStreamTrack) -> Void)?
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
