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

    /// The connection's audio for the application to play and feed, when its
    /// configuration's `audioPlayback` is `.application`; nil otherwise.
    nonisolated var applicationAudio: (any CommunicationApplicationAudio)? { get }

    /// The local description as it currently stands, including whatever ICE
    /// candidates have been gathered so far.
    var localDescription: CommunicationSessionDescription? { get async }

    /// How far ICE gathering has got.
    var iceGatheringState: CommunicationICEGatheringState { get async }

    /// Whether a local microphone track is currently attached — i.e. whether
    /// a call is in progress on this connection.


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

    // MARK: Media (RTCPeerConnection's track and transceiver methods)

    func addTrack(_ track: any CommunicationMediaStreamTrack, streamIDs: [String]) async throws -> any CommunicationRtpSender

    func removeTrack(_ sender: any CommunicationRtpSender) async throws

    func addTransceiver(kind: CommunicationMediaKind, direction: CommunicationTransceiverDirection) async throws -> any CommunicationRtpTransceiver

    var transceivers: [any CommunicationRtpTransceiver] { get async }

    var senders: [any CommunicationRtpSender] { get async }

    var receivers: [any CommunicationRtpReceiver] { get async }
}

// Protocols cannot carry default arguments; the conveniences live here so
// call sites read the same against any implementation.
extension CommunicationPeerConnection {
    /// Backends without application audio have none.
    public nonisolated var applicationAudio: (any CommunicationApplicationAudio)? { nil }
}

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
    /// Creates a peer connection: data channels, media, and negotiation.
    func makePeerConnection(configuration: CommunicationConfiguration) throws -> any CommunicationPeerConnection

    /// The device side (`getUserMedia`): tracks usable on this connector's
    /// peer connections.
    func makeMediaDevices() throws -> any CommunicationMediaDevices
}

extension CommunicationConnector {
    /// A peer connection with the default configuration.
    public func makePeerConnection() throws -> any CommunicationPeerConnection {
        try makePeerConnection(configuration: CommunicationConfiguration())
    }
}
