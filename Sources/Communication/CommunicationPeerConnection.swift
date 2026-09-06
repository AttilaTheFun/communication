import Foundation

/// One WebRTC peer connection, as the Communication API sees it.
///
/// This protocol is the currency of the Communication package: applications
/// and higher-level packages hold `any CommunicationPeerConnection` and stay
/// oblivious to which platform implementation is underneath — Google's
/// WebRTC on Apple platforms (`CommunicationWebRTC`), and other platform
/// backends as they land. Implementations are expected to be actors or
/// otherwise `Sendable`, with every operation `async`.
///
/// A peer connection represents the WebRTC transport relationship between
/// this local process and one remote peer. It can carry multiple flows over
/// that relationship: audio tracks, video tracks, and data channels.
///
/// Signalling is intentionally outside this type. Callers create SDP offers
/// and answers with `offer(options:)` and `answer(options:)`, carry the
/// resulting `CommunicationSessionDescription` values to the remote peer over
/// their own transport, and apply what comes back with
/// `setRemoteDescription(_:)`. Local ICE candidates arrive through `events`
/// as `.localCandidateDiscovered` and travel the same way; remote ones are
/// applied with `addRemoteCandidate(_:)`.
public protocol CommunicationPeerConnection: Sendable {
    /// Events emitted by the underlying peer connection: negotiation,
    /// connection-state changes, ICE progress, data channels, remote media.
    nonisolated var events: AsyncStream<CommunicationEvent> { get }

    /// The local description as it currently stands, including whatever ICE
    /// candidates have been gathered so far.
    var localDescription: CommunicationSessionDescription? { get async }

    /// How far ICE gathering has got.
    var iceGatheringState: CommunicationICEGatheringState { get async }

    /// Whether a local microphone track is currently attached — i.e. whether
    /// a call is in progress on this connection.
    var hasLocalAudio: Bool { get async }

    /// Opens a data channel.
    ///
    /// Only one side calls this; the other receives the same channel through
    /// `.dataChannelOpened` and can `send` on it without opening anything. By
    /// convention the offering side opens the channel before creating its
    /// offer, so the channel is negotiated as part of that exchange.
    func openDataChannel(label: String, configuration: CommunicationDataChannelConfiguration) async throws

    /// Sends text on a data channel. With a nil label, sends on the only
    /// open channel — unambiguous for the common single-channel case, and an
    /// error rather than a guess when there are several.
    func send(text: String, on label: String?) async throws

    /// Sends binary data on a data channel.
    func send(data: Data, on label: String?) async throws

    /// Creates an SDP offer.
    func offer(options: CommunicationOfferOptions) async throws -> CommunicationSessionDescription

    /// Creates an SDP answer.
    func answer(options: CommunicationAnswerOptions) async throws -> CommunicationSessionDescription

    /// Applies a local session description.
    func setLocalDescription(_ description: CommunicationSessionDescription) async throws

    /// Applies a remote session description.
    func setRemoteDescription(_ description: CommunicationSessionDescription) async throws

    /// Adds an ICE candidate received from the remote peer.
    func addRemoteCandidate(_ candidate: CommunicationICECandidate) async throws

    /// Requests an ICE restart.
    func restartICE() async

    /// Closes the peer connection and finishes its event stream.
    func close() async

    /// Adds a local microphone track to the live connection, turning a
    /// data-only session into a call. The set of media lines changes, so the
    /// caller must renegotiate afterwards. Returns whether a local audio
    /// track is now attached.
    @discardableResult
    func addLocalAudio() async -> Bool

    /// Removes the local microphone track, ending the call while leaving the
    /// connection and its data channels intact. Renegotiate afterwards.
    func removeLocalAudio() async

    /// Mutes or unmutes the local outgoing audio track.
    func setLocalAudioMuted(_ muted: Bool) async

    /// Sets the local outgoing audio gain (`0...1`, clamped).
    func setLocalAudioGain(_ gain: Float) async

    /// Mutes or unmutes local playback of remote audio.
    func setRemoteAudioPlaybackMuted(_ muted: Bool) async

    /// Sets local playback volume for remote audio (`0...1`, clamped).
    func setRemoteAudioPlaybackVolume(_ volume: Float) async

    /// Adds a local camera track to the live connection, turning a call into
    /// a video call. As with audio, the set of media lines changes, so the
    /// caller must renegotiate afterwards. Returns whether a local video
    /// track is now attached. Backends without a camera return false.
    @discardableResult
    func addLocalVideo() async -> Bool

    /// Removes the local camera track and stops capturing. Renegotiate
    /// afterwards.
    func removeLocalVideo() async

    /// Whether a local camera track is currently attached.
    var hasLocalVideo: Bool { get async }
}

// Video is optional for a backend: one without a camera simply declines.
extension CommunicationPeerConnection {
    @discardableResult
    public func addLocalVideo() async -> Bool { false }
    public func removeLocalVideo() async {}
    public var hasLocalVideo: Bool { get async { false } }
}

// Protocols cannot carry default arguments; the conveniences live here so
// call sites read the same against any implementation.
extension CommunicationPeerConnection {
    /// Opens a data channel with the default (ordered, reliable) delivery.
    public func openDataChannel(label: String) async throws {
        try await openDataChannel(label: label, configuration: CommunicationDataChannelConfiguration())
    }

    /// Sends text on the only open data channel.
    public func send(text: String) async throws {
        try await send(text: text, on: nil)
    }

    /// Sends binary data on the only open data channel.
    public func send(data: Data) async throws {
        try await send(data: data, on: nil)
    }

    /// Creates an SDP offer with default options.
    public func offer() async throws -> CommunicationSessionDescription {
        try await offer(options: CommunicationOfferOptions())
    }

    /// Creates an SDP answer with default options.
    public func answer() async throws -> CommunicationSessionDescription {
        try await answer(options: CommunicationAnswerOptions())
    }
}

/// Creates peer connections for one platform implementation.
///
/// Applications that want implementation-independence inject one of these
/// (the Apple package provides `WebRTCConnector`) and never name a concrete
/// peer connection type.
public protocol CommunicationConnector: Sendable {
    /// Creates a peer connection.
    ///
    /// - Parameters:
    ///   - configuration: The ICE and peer connection configuration.
    ///   - createsLocalAudioTrack: Whether to attach a microphone track at
    ///     setup. Defaults to false via the convenience below: a connection
    ///     that starts as data-only should add audio when a call begins.
    func makePeerConnection(
        configuration: CommunicationConfiguration,
        createsLocalAudioTrack: Bool
    ) throws -> any CommunicationPeerConnection
}

extension CommunicationConnector {
    /// Creates a data-only peer connection with the given configuration.
    public func makePeerConnection(
        configuration: CommunicationConfiguration = CommunicationConfiguration()
    ) throws -> any CommunicationPeerConnection {
        try makePeerConnection(configuration: configuration, createsLocalAudioTrack: false)
    }
}
