import Foundation

import Communication

#if canImport(UIKit)
import UIKit
/// The platform view a call's video renders into.
public typealias CommunicationVideoView = UIView
#elseif canImport(AppKit)
import AppKit
public typealias CommunicationVideoView = NSView
#endif

@preconcurrency internal import WebRTC

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
/// openings, and remote media attachment. Audio controls on this type affect
/// only this peer connection: local microphone mute/gain controls the outgoing
/// audio track, while remote playback mute/volume controls how this process
/// hears the remote peer.
public actor WebRTCPeerConnection: CommunicationPeerConnection {
    /// Internal owner of the raw WebRTC peer connection.
    private let core: PeerConnectionCore

    /// Events emitted by the underlying peer connection.
    public nonisolated let events: AsyncStream<CommunicationEvent>

    /// Creates a peer connection.
    ///
    /// - Parameters:
    ///   - configuration: The ICE and peer connection configuration.
    ///   - createsLocalAudioTrack: Whether to attach a microphone track at
    ///     setup. Defaults to `false`: a connection that starts as data-only
    ///     (a chat that may later place a call) should add audio when the
    ///     call begins via `addLocalAudio()`, not carry a live mic from the
    ///     start.
    public init(
        configuration: CommunicationConfiguration = CommunicationConfiguration(),
        createsLocalAudioTrack: Bool = false
    ) throws {
        let core = try PeerConnectionCore(
            configuration: configuration,
            createsLocalAudioTrack: createsLocalAudioTrack
        )
        self.core = core
        self.events = core.events
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

    // MARK: - Mid-call audio

    /// Adds a local microphone track to the live connection, turning a
    /// data-only session into a call. The set of media lines changes, so the
    /// caller must renegotiate afterwards: create a new offer (or answer),
    /// apply it locally, and exchange it with the peer.
    ///
    /// - Returns: Whether a local audio track is now attached.
    @discardableResult
    public func addLocalAudio() -> Bool {
        core.addLocalAudioTrack()
    }

    /// Removes the local microphone track, ending the call while leaving the
    /// connection and its data channels intact. Renegotiate afterwards, as
    /// with `addLocalAudio()`.
    public func removeLocalAudio() {
        core.removeLocalAudioTrack()
    }

    /// Whether a local microphone track is currently attached — i.e. whether
    /// a call is in progress on this connection.
    public var hasLocalAudio: Bool {
        core.hasLocalAudio
    }

    /// Mutes or unmutes the local outgoing audio track.
    ///
    /// - Parameter muted: Whether outgoing local audio should be muted.
    public func setLocalAudioMuted(_ muted: Bool) {
        core.setLocalAudioMuted(muted)
    }

    /// Sets the local outgoing audio gain.
    ///
    /// - Parameter gain: A value in `0...1`; values outside the range are clamped.
    public func setLocalAudioGain(_ gain: Float) {
        core.setLocalAudioGain(gain)
    }

    /// Mutes or unmutes local playback of remote audio.
    ///
    /// - Parameter muted: Whether remote audio playback should be muted locally.
    public func setRemoteAudioPlaybackMuted(_ muted: Bool) {
        core.setRemoteAudioPlaybackMuted(muted)
    }

    /// Sets local playback volume for remote audio.
    ///
    /// - Parameter volume: A value in `0...1`; values outside the range are clamped.
    public func setRemoteAudioPlaybackVolume(_ volume: Float) {
        core.setRemoteAudioPlaybackVolume(volume)
    }

    // MARK: - Mid-call video

    /// Adds the camera to the live connection. Renegotiate afterwards, as
    /// with `addLocalAudio()`.
    @discardableResult
    public func addLocalVideo() -> Bool {
        core.addLocalVideoTrack()
    }

    /// Removes the camera track and stops capturing. Renegotiate afterwards.
    public func removeLocalVideo() {
        core.removeLocalVideoTrack()
    }

    public var hasLocalVideo: Bool {
        core.hasLocalVideo
    }

    // MARK: - Video views
    //
    // Metal-backed views the app places wherever it shows a call. Each view
    // renders whatever track is (or later becomes) attached, so they can be
    // made before the call's media arrives.

    /// A view showing this device's own camera.
    @MainActor
    public func makeLocalVideoView() -> CommunicationVideoView {
        let view = Self.makeMetalVideoView()
        core.addLocalVideoRenderer(view)
        return view
    }

    /// A view showing the peer's camera.
    @MainActor
    public func makeRemoteVideoView() -> CommunicationVideoView {
        let view = Self.makeMetalVideoView()
        core.addRemoteVideoRenderer(view)
        return view
    }

    #if canImport(UIKit)
    @MainActor
    private static func makeMetalVideoView() -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFill
        return view
    }
    #else
    @MainActor
    private static func makeMetalVideoView() -> RTCMTLNSVideoView {
        RTCMTLNSVideoView(frame: .zero)
    }
    #endif
}
