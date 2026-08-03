import Foundation

/// How a data channel delivers messages.
///
/// The default is the one most application protocols want: ordered and fully
/// reliable, i.e. TCP semantics over the peer connection. The unreliable modes
/// exist for traffic where a late message is worse than a missing one.
public struct CommunicationDataChannelConfiguration: Sendable, Equatable {
    /// Whether messages arrive in the order they were sent.
    public var ordered: Bool
    /// Give up on a message after this many milliseconds; nil means never.
    public var maxRetransmitTimeMilliseconds: Int?
    /// Give up after this many retransmits; nil means keep trying.
    public var maxRetransmits: Int?
    /// Negotiated out of band, with both sides agreeing this id in advance.
    public var channelID: Int32?

    public init(
        ordered: Bool = true,
        maxRetransmitTimeMilliseconds: Int? = nil,
        maxRetransmits: Int? = nil,
        channelID: Int32? = nil
    ) {
        self.ordered = ordered
        self.maxRetransmitTimeMilliseconds = maxRetransmitTimeMilliseconds
        self.maxRetransmits = maxRetransmits
        self.channelID = channelID
    }
}

/// The state of a data channel, mirroring RTCDataChannelState.
public enum CommunicationDataChannelState: String, Sendable {
    case connecting
    case open
    case closing
    case closed
}

/// A message that arrived on a data channel.
///
/// WebRTC distinguishes text from binary on the wire, and that distinction is
/// preserved rather than flattened: a peer that sent bytes should not have
/// them come back as a lossily-decoded string.
public enum CommunicationDataChannelMessage: Sendable, Equatable {
    case text(String)
    case binary(Data)
}
