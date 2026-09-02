/// The overall state of a WebRTC peer connection.
public enum CommunicationConnectionState: String, Sendable, CaseIterable {
    /// The connection was created but has not started connecting.
    case fresh

    /// The connection is checking candidate pairs and negotiating connectivity.
    case connecting

    /// The connection is established.
    case connected

    /// The connection was interrupted but may recover.
    case disconnected

    /// The connection failed.
    case failed

    /// The connection was closed.
    case closed

    /// WebRTC reported a state unknown to this wrapper.
    case unknown
}
