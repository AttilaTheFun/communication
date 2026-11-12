#if canImport(LiveKitWebRTC)
import Foundation

import Communication

@preconcurrency internal import LiveKitWebRTC

/// The Apple implementation of `CommunicationPeerConnection`, backed by
/// Google's WebRTC (the stasel/WebRTC binary distribution).
///
/// A thin, value-oriented Swift wrapper around a single WebRTC peer
/// connection. Use this type when an application or higher-level package
/// wants to own call membership and signalling itself, but does not want to
/// work directly with raw WebRTC types.
///
/// A peer connection represents the WebRTC transport relationship between this
/// local process and one remote peer, client, device, or session. It can carry
/// multiple flows over that relationship, including audio tracks, video tracks,
/// and data channels.
///
/// The connection is configured with `CommunicationConfiguration`,
/// which includes ICE (Interactive Connectivity Establishment) server and policy settings.
/// ICE is WebRTC's process for discovering a usable network path between peers.
///
/// ICE servers are usually STUN (Session Traversal Utilities for NAT) servers,
/// which help peers discover their public network address,
/// or TURN (Traversal Using Relays around NAT) servers,
/// which relay media when a direct path is unavailable.
///
/// Signalling is intentionally outside this type.
///
/// Callers create SDP (Session Description Protocol) offers and answers with `offer(options:)`
/// and `answer(options:)`, send the resulting `CommunicationSessionDescription`
/// values to a remote peer through their own signalling transport, and apply
/// remote descriptions with `setRemoteDescription(_:)`.
///
/// Likewise, local ICE candidates arrive through `events` as `CommunicationEvent.localCandidateDiscovered`
/// and should be sent to the remote peer; remote ICE candidates are applied with
/// `addRemoteCandidate(_:)`.
///
/// The event stream publishes `CommunicationEvent` values for negotiation,
/// connection-state changes, ICE gathering and connectivity state, data-channel
/// openings, and track arrival. Tracks come from `WebRTCMediaDevices` (or a
/// receiver) and go on through `addTrack`/`addTransceiver`, as in the spec.
public actor WebRTCPeerConnection: CommunicationPeerConnection {
    /// Internal owner of the raw WebRTC peer connection.
    private let core: PeerConnectionCore

    /// Events emitted by the underlying peer connection.
    public nonisolated let events: AsyncStream<CommunicationEvent>

    /// This connection's audio for the application to play and feed, when
    /// the configuration asked for `.application` playback.
    public nonisolated let applicationAudio: (any CommunicationApplicationAudio)?

    /// Creates a peer connection.
    ///
    /// - Parameters:
    ///   - configuration: The ICE and peer connection configuration.
    public init(configuration: CommunicationConfiguration = CommunicationConfiguration()) throws {
        let core = try PeerConnectionCore(configuration: configuration)
        self.core = core
        self.events = core.events
        self.applicationAudio = core.applicationAudio
    }

    /// The local description as it currently stands, including whatever ICE
    /// candidates have been gathered so far.
    public var localDescription: CommunicationSessionDescription? {
        core.localDescription
    }

    /// How far ICE gathering has got.
    public var iceGatheringState: CommunicationICEGatheringState {
        core.iceGatheringState
    }

    // MARK: - Data channels

    /// Opens a data channel.
    ///
    /// Only one side calls this; the other receives the same channel through
    /// `dataChannelOpened` and can `send` on it without opening anything. By
    /// convention the offering side opens the channel before creating its
    /// offer, so the channel is negotiated as part of that exchange.
    public func openDataChannel(
        label: String,
        configuration: CommunicationDataChannelConfiguration = CommunicationDataChannelConfiguration()
    ) throws {
        try core.openDataChannel(label: label, configuration: configuration)
    }

    /// Sends text on a data channel.
    ///
    /// With no label, sends on the only open channel — unambiguous for the
    /// common case of a connection with a single channel, and an error rather
    /// than a guess when there are several.
    public func send(text: String, on label: String? = nil) throws {
        try core.send(.text(text), label: label)
    }

    /// Sends binary data on a data channel.
    public func send(data: Data, on label: String? = nil) throws {
        try core.send(.binary(data), label: label)
    }

    /// Creates an SDP offer.
    ///
    /// - Parameter options: Media and ICE negotiation options.
    /// - Returns: The generated local session description.
    public func offer(
        options: CommunicationOfferOptions = CommunicationOfferOptions()
    ) async throws -> CommunicationSessionDescription {
        try await core.offer(options: options)
    }

    /// Creates an SDP answer.
    ///
    /// - Parameter options: Media and ICE negotiation options.
    /// - Returns: The generated local session description.
    public func answer(
        options: CommunicationAnswerOptions = CommunicationAnswerOptions()
    ) async throws -> CommunicationSessionDescription {
        try await core.answer(options: options)
    }

    /// Applies a local session description to the peer connection.
    ///
    /// - Parameter description: The local offer or answer.
    public func setLocalDescription(
        _ description: CommunicationSessionDescription
    ) async throws {
        try await core.setLocalDescription(description)
    }

    /// Applies a remote session description to the peer connection.
    ///
    /// - Parameter description: The remote offer or answer.
    public func setRemoteDescription(
        _ description: CommunicationSessionDescription
    ) async throws {
        try await core.setRemoteDescription(description)
    }

    /// Adds an ICE candidate received from the remote peer.
    ///
    /// - Parameter candidate: The remote ICE candidate.
    public func addRemoteCandidate(_ candidate: CommunicationICECandidate) async throws {
        try await core.addRemoteCandidate(candidate)
    }

    /// Requests an ICE restart on the underlying peer connection.
    public func restartICE() {
        core.restartICE()
    }

    /// Closes the peer connection and finishes its event stream.
    public func close() {
        core.close()
    }

    // MARK: - Media

    public func addTrack(_ track: any CommunicationMediaStreamTrack, streamIDs: [String]) throws -> any CommunicationRtpSender {
        try core.addTrack(track, streamIDs: streamIDs)
    }

    public func removeTrack(_ sender: any CommunicationRtpSender) throws {
        try core.removeTrack(sender)
    }

    public func addTransceiver(kind: CommunicationMediaKind, direction: CommunicationTransceiverDirection) throws -> any CommunicationRtpTransceiver {
        try core.addTransceiver(kind: kind, direction: direction)
    }

    public var transceivers: [any CommunicationRtpTransceiver] { core.transceivers }
    public var senders: [any CommunicationRtpSender] { core.senders }
    public var receivers: [any CommunicationRtpReceiver] { core.receivers }
}
#endif
