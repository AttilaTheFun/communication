/// The WebRTC primitives `CommunicationCore` needs from a platform, in the
/// W3C WebRTC vocabulary: what every platform's adapter implements, and the
/// only per-platform code there is.
///
/// - The browser's adapter passes values straight through to
///   `RTCPeerConnection`; libwebrtc's adapters (Kotlin on Android; Swift on
///   Apple, Linux and Windows) translate from its enums, which match.
/// - Values that aren't plain strings are JSON of the W3C dictionaries
///   (`RTCConfiguration`, `RTCSessionDescriptionInit`, `RTCIceCandidateInit`,
///   `RTCOfferOptions`, `RTCDataChannelInit`); see `W3C.swift`.
/// - States are the W3C strings (`"new"`, `"have-local-offer"`, …).
/// - Bytes are `[UInt8]`.
///
/// Connections are named by the id `create` returns. Events are pulled:
/// the core awaits `nextEvent` in a loop, and the host answers each call
/// with the next thing that happened on that connection, ending with
/// `.closed`. The same shape is a swift_ffi interface for Isomer's web and
/// Android hosts, where the host can't call into Swift on its own.
public protocol WebRTCHost: Sendable {
    /// Creates a peer connection from an `RTCConfiguration` (JSON), with the
    /// libwebrtc-only options under `"native"`, which a browser ignores.
    func create(configuration: String) async throws -> Int32
    /// `RTCSessionDescriptionInit` (JSON) of a new offer.
    func createOffer(connection: Int32, options: String) async throws -> String
    /// `RTCSessionDescriptionInit` (JSON) of a new answer.
    func createAnswer(connection: Int32, options: String) async throws -> String
    func setLocalDescription(connection: Int32, description: String) async throws
    func setRemoteDescription(connection: Int32, description: String) async throws
    /// The current local description (JSON), or "" when there is none.
    func localDescription(connection: Int32) async -> String
    /// Adds a remote `RTCIceCandidateInit` (JSON).
    func addCandidate(connection: Int32, candidate: String) async throws
    func restartICE(connection: Int32) async
    /// Opens a data channel with an `RTCDataChannelInit` (JSON). The host
    /// reports it with `.channelState` as it opens, as it does for channels
    /// the remote opens.
    func openDataChannel(connection: Int32, label: String, configuration: String) async throws
    func sendText(connection: Int32, channel: String, text: String) async throws
    func sendData(connection: Int32, channel: String, data: [UInt8]) async throws
    /// The next event on the connection. After `.closed`, every call answers
    /// `.closed` again.
    func nextEvent(connection: Int32) async throws -> WebRTCHostEvent
    /// Closes the connection and its channels; a pending `nextEvent` answers
    /// `.closed`. (Not `close`: swift_ffi's generated proxies have their own.)
    func disconnect(connection: Int32) async
}

/// One thing that happened on a connection. `kind` says which, and which of
/// the other fields it uses.
public struct WebRTCHostEvent: Sendable, Equatable {
    public enum Kind: Int32, Sendable {
        /// The connection is gone; no more events follow.
        case closed = 0
        /// `text`: the W3C signaling state.
        case signalingState = 1
        /// `text`: the W3C ICE connection state.
        case iceConnectionState = 2
        /// `text`: the W3C connection state.
        case connectionState = 3
        /// `text`: the W3C ICE gathering state.
        case iceGatheringState = 4
        /// `text`: a local `RTCIceCandidateInit` (JSON).
        case candidate = 5
        /// `text`: the local candidates removed, as a JSON array of
        /// `RTCIceCandidateInit` (libwebrtc only).
        case candidatesRemoved = 6
        case negotiationNeeded = 7
        /// `channel`, and `text`: its W3C ready state. A channel the remote
        /// opened is reported here first, like one opened locally.
        case channelState = 8
        /// `channel` and `text`.
        case textMessage = 9
        /// `channel` and `data`.
        case dataMessage = 10
    }

    public var kind: Int32
    public var channel: String
    public var text: String
    public var data: [UInt8]

    public init(kind: Int32, channel: String = "", text: String = "", data: [UInt8] = []) {
        self.kind = kind
        self.channel = channel
        self.text = text
        self.data = data
    }

    public init(_ kind: Kind, channel: String = "", text: String = "", data: [UInt8] = []) {
        self.init(kind: kind.rawValue, channel: channel, text: text, data: data)
    }
}
